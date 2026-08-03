import argparse
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Self
from urllib.parse import quote, urlparse

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator


class Error(RuntimeError):
    pass


class LockedInput(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    type: str
    rev: str | None = None
    ref: str | None = None
    url: str | None = None
    path: str | None = None
    nar_hash: str | None = Field(default=None, alias="narHash")
    host: str | None = None
    owner: str | None = None
    repo: str | None = None


class LockNode(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    inputs: dict[str, str | list[str]] = Field(default_factory=dict)
    locked: LockedInput | None = None


class FlakeLock(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    nodes: dict[str, LockNode]
    root: str
    version: int

    @model_validator(mode="after")
    def validate_root(self) -> Self:
        if self.root not in self.nodes:
            raise ValueError(f"root node {self.root!r} is missing")
        return self


@dataclass(frozen=True)
class Repository:
    host: str
    owner: str
    name: str


@dataclass(frozen=True)
class Update:
    name: str
    old: LockedInput
    new: LockedInput


def load_lock(path: Path) -> FlakeLock:
    try:
        return FlakeLock.model_validate_json(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise Error(f"failed to read {path}: {exc}") from exc
    except ValidationError as exc:
        raise Error(f"invalid flake lock {path}: {exc}") from exc


def locked_inputs(lock: FlakeLock) -> dict[str, LockedInput]:
    inputs: dict[str, LockedInput] = {}

    def visit(node_name: str, path: tuple[str, ...], ancestors: set[str]) -> None:
        node = lock.nodes[node_name]
        for name, child_name in node.inputs.items():
            if not isinstance(child_name, str) or child_name in ancestors:
                continue

            child = lock.nodes.get(child_name)
            if child is None:
                continue
            child_path = (*path, name)
            if child.locked is not None:
                inputs["/".join(child_path)] = child.locked
            visit(child_name, child_path, ancestors | {child_name})

    visit(lock.root, (), {lock.root})
    return inputs


def revision(locked: LockedInput) -> str:
    return next(
        (
            value
            for value in (
                locked.rev,
                locked.ref,
                locked.url,
                locked.path,
                locked.nar_hash,
            )
            if value
        ),
        "unknown",
    )


def display_revision(value: str) -> str:
    if len(value) >= 12 and all(character in "0123456789abcdef" for character in value.lower()):
        return value[:7]
    return value


def github_repository(locked: LockedInput) -> Repository | None:
    if locked.type == "github":
        if locked.owner is None or locked.repo is None:
            return None
        return Repository(locked.host or "github.com", locked.owner, locked.repo)

    if locked.type != "git" or locked.url is None:
        return None

    parsed = urlparse(locked.url.removeprefix("git+"))
    if parsed.hostname != "github.com":
        return None

    parts = parsed.path.removesuffix(".git").strip("/").split("/")
    if len(parts) != 2:
        return None
    return Repository(parsed.hostname, parts[0], parts[1])


def gitlab_repository(locked: LockedInput) -> Repository | None:
    if locked.type != "gitlab" or locked.owner is None or locked.repo is None:
        return None
    return Repository(locked.host or "gitlab.com", locked.owner, locked.repo)


def compare_url(old: LockedInput, new: LockedInput) -> str | None:
    if old.rev is None or new.rev is None:
        return None

    old_github = github_repository(old)
    new_github = github_repository(new)
    if old_github is not None and old_github == new_github:
        return (
            f"https://{new_github.host}/{quote(new_github.owner)}/"
            f"{quote(new_github.name)}/compare/{quote(old.rev)}...{quote(new.rev)}"
        )

    old_gitlab = gitlab_repository(old)
    new_gitlab = gitlab_repository(new)
    if old_gitlab is not None and old_gitlab == new_gitlab:
        return (
            f"https://{new_gitlab.host}/{quote(new_gitlab.owner)}/"
            f"{quote(new_gitlab.name)}/-/compare/{quote(old.rev)}...{quote(new.rev)}"
        )

    return None


def updated_inputs(old_lock: FlakeLock, new_lock: FlakeLock) -> list[Update]:
    old_inputs = locked_inputs(old_lock)
    new_inputs = locked_inputs(new_lock)
    return [
        Update(name, old_inputs[name], new_inputs[name])
        for name in sorted(old_inputs.keys() & new_inputs.keys())
        if old_inputs[name] != new_inputs[name]
    ]


def render_body(old_lock: FlakeLock, new_lock: FlakeLock, trigger: str) -> str:
    updates = updated_inputs(old_lock, new_lock)
    lines = ["Automated update of flake inputs.", ""]

    if updates:
        lines.extend(["| Input | Update | Diff |", "| --- | --- | --- |"])
        for update in updates:
            old_revision = revision(update.old)
            new_revision = revision(update.new)
            comparison = compare_url(update.old, update.new)
            diff = f"[Compare]({comparison})" if comparison else "Unavailable"
            lines.append(
                f"| `{update.name}` | `{display_revision(old_revision)}` → "
                f"`{display_revision(new_revision)}` | {diff} |"
            )
    else:
        lines.append("No flake input revisions changed.")

    lines.extend(["", "Generated by GitHub Actions.", f"Trigger: {trigger}"])
    return "\n".join(lines) + "\n"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a pull request body for flake input updates."
    )
    parser.add_argument("old_lock", type=Path)
    parser.add_argument("new_lock", type=Path)
    parser.add_argument("--trigger", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        body = render_body(load_lock(args.old_lock), load_lock(args.new_lock), args.trigger)
        args.output.write_text(body, encoding="utf-8")
    except Error as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
