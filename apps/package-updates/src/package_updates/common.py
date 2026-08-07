from __future__ import annotations

import json
import os
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TextIO

from atomic_file_writes import write_text_atomic


class UpdateError(RuntimeError):
    """A user-facing update failure."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class Runner(Protocol):
    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Path,
        environment: Mapping[str, str] | None = None,
        capture: bool = True,
    ) -> CommandResult: ...


class SubprocessRunner:
    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Path,
        environment: Mapping[str, str] | None = None,
        capture: bool = True,
    ) -> CommandResult:
        completed = subprocess.run(
            arguments,
            cwd=cwd,
            env=None if environment is None else dict(environment),
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
        return CommandResult(
            returncode=completed.returncode,
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
        )


@dataclass(frozen=True)
class ToolPaths:
    nix: str
    nix_update: str
    nix_prefetch_docker: str
    skopeo: str
    select_nodejs: str

    @classmethod
    def from_environment(cls) -> ToolPaths:
        return cls(
            nix=os.environ.get("PACKAGE_UPDATES_NIX", "nix"),
            nix_update=os.environ.get("PACKAGE_UPDATES_NIX_UPDATE", "nix-update"),
            nix_prefetch_docker=os.environ.get(
                "PACKAGE_UPDATES_NIX_PREFETCH_DOCKER", "nix-prefetch-docker"
            ),
            skopeo=os.environ.get("PACKAGE_UPDATES_SKOPEO", "skopeo"),
            select_nodejs=os.environ.get(
                "PACKAGE_UPDATES_SELECT_NODEJS",
                str(Path(sys.argv[0]).resolve().with_name("select-nodejs")),
            ),
        )


def find_repo_root(start: Path) -> Path:
    candidate = start.resolve()
    for directory in (candidate, *candidate.parents):
        if (directory / ".git").exists() and (directory / "flake.nix").is_file():
            return directory
    raise UpdateError(f"not inside the repository: {start}")


def atomic_write_json(path: Path, value: object) -> None:
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    content = json.dumps(value, indent=2, sort_keys=True) + "\n"
    write_text_atomic(path, content, mode=mode)


def checked(result: CommandResult, description: str) -> str:
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise UpdateError(f"{description} failed{suffix}")
    return result.stdout


def print_error(error: Exception, stderr: TextIO) -> int:
    print(str(error), file=stderr)
    return 1
