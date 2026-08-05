from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TextIO

from pydantic import ValidationError

from package_updates.common import (
    Runner,
    SubprocessRunner,
    ToolPaths,
    UpdateError,
    checked,
    find_repo_root,
    print_error,
)
from package_updates.models import PackageTarget, PackageTargets
from package_updates.summary import (
    compare_from_changelogs,
    compare_from_sources,
    markdown_link,
)

SUMMARY_HEADER = """Automated package source update.

Package builds were not run by the updater. Normal CI is expected to validate
whether the updated package still builds or needs follow-up fixes.

| Package | Version | Changelog | Diff |
| --- | --- | --- | --- |
"""


@dataclass(frozen=True)
class PackageMetadata:
    version: str = ""
    changelog: str = ""
    homepage: str = ""
    source_revision: str = ""


class PackageBackend(Protocol):
    def metadata(self, target: PackageTarget) -> PackageMetadata: ...

    def update(self, target: PackageTarget) -> None: ...


def parse_update_script(value: object, attribute: str) -> tuple[str, ...] | None:
    if value is None:
        return None
    if isinstance(value, str):
        return (value,)
    if isinstance(value, list):
        if not value:
            return None
        if all(isinstance(argument, str) for argument in value):
            return tuple(value)
        raise UpdateError(f"passthru.updateScript for {attribute} contains a non-string argument")
    raise UpdateError(
        f"unsupported passthru.updateScript type for {attribute}: {type(value).__name__}"
    )


class CommandPackageBackend:
    def __init__(self, repo_root: Path, tools: ToolPaths, runner: Runner) -> None:
        self.repo_root = repo_root
        self.tools = tools
        self.runner = runner

    def _eval(self, expression: str, output_format: str) -> str | None:
        result = self.runner.run(
            [
                self.tools.nix,
                "eval",
                "--option",
                "eval-cache",
                "false",
                output_format,
                expression,
            ],
            cwd=self.repo_root,
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def metadata(self, target: PackageTarget) -> PackageMetadata:
        prefix = f".#packages.{target.system}.{target.attr}"
        return PackageMetadata(
            version=self._eval(f"{prefix}.version", "--raw") or "",
            changelog=self._eval(f"{prefix}.meta.changelog", "--raw") or "",
            homepage=self._eval(f"{prefix}.meta.homepage", "--raw") or "",
            source_revision=self._eval(f"{prefix}.src.rev", "--raw") or "",
        )

    def _run_update_script(self, target: PackageTarget) -> bool:
        installable = f".#packages.{target.update_system}.{target.attr}.passthru.updateScript"
        build = self.runner.run(
            [self.tools.nix, "build", "--no-link", "--print-out-paths", installable],
            cwd=self.repo_root,
        )
        arguments: tuple[str, ...] | None = None
        if build.returncode == 0 and build.stdout.splitlines():
            output = Path(build.stdout.splitlines()[0])
            main_program = self._eval(f"{installable}.meta.mainProgram", "--raw")
            candidate = output / "bin" / main_program if main_program else output
            if candidate.is_file() and os.access(candidate, os.X_OK):
                arguments = (str(candidate),)
            elif output.is_file() and os.access(output, os.X_OK):
                arguments = (str(output),)
            else:
                raise UpdateError(
                    f"could not find executable for passthru.updateScript of {target.attr}"
                )
        else:
            encoded = self._eval(installable, "--json")
            if encoded:
                try:
                    arguments = parse_update_script(json.loads(encoded), target.attr)
                except json.JSONDecodeError as error:
                    raise UpdateError(
                        f"invalid passthru.updateScript JSON for {target.attr}: {error}"
                    ) from error

        if arguments is None:
            return False

        print("running passthru.updateScript")
        environment = os.environ | {
            "UPDATE_NIX_ATTR_PATH": target.attr,
            "UPDATE_NIX_SYSTEM": target.update_system,
            "PACKAGE_UPDATES_SELECT_NODEJS": self.tools.select_nodejs,
        }
        checked(
            self.runner.run(
                arguments,
                cwd=self.repo_root,
                environment=environment,
                capture=False,
            ),
            f"passthru.updateScript for {target.attr}",
        )
        return True

    def update(self, target: PackageTarget) -> None:
        if self._run_update_script(target):
            return
        checked(
            self.runner.run(
                [
                    self.tools.nix_update,
                    "--flake",
                    "--system",
                    target.update_system,
                    *target.nix_update_args,
                    target.attr,
                ],
                cwd=self.repo_root,
                capture=False,
            ),
            f"nix-update for {target.attr}",
        )


def load_targets(path: Path) -> PackageTargets:
    return PackageTargets.model_validate_json(path.read_text())


def selected_targets(
    targets: PackageTargets, target_filter: str | None
) -> tuple[PackageTarget, ...]:
    selected = tuple(
        target
        for target in targets.targets
        if target_filter is None or target.attr == target_filter
    )
    if not selected:
        raise UpdateError("No package update targets matched.")
    return selected


def version_text(old_version: str, new_version: str) -> str:
    if old_version and new_version and old_version != new_version:
        return f"{old_version} -> {new_version}"
    return new_version or "unknown"


def summary_row(
    target: PackageTarget,
    old: PackageMetadata,
    new: PackageMetadata,
) -> str:
    comparison = compare_from_sources(
        old.homepage,
        old.source_revision,
        new.homepage,
        new.source_revision,
    ) or compare_from_changelogs(old.changelog, new.changelog)
    return (
        f"| `{target.attr}` | `{version_text(old.version, new.version)}` | "
        f"{markdown_link('link', new.changelog)} | "
        f"{markdown_link('compare', comparison)} |\n"
    )


def update_packages(
    targets: Sequence[PackageTarget],
    summary_file: Path,
    backend: PackageBackend,
    stdout: TextIO,
) -> None:
    summary_file.parent.mkdir(parents=True, exist_ok=True)
    summary_file.write_text(SUMMARY_HEADER)
    with summary_file.open("a") as summary:
        for target in targets:
            old = backend.metadata(target)
            print(f"::group::Updating {target.attr}", file=stdout)
            print(f"system: {target.system}", file=stdout)
            if target.update_system != target.system:
                print(f"nix-update system: {target.update_system}", file=stdout)
            if old.version:
                print(f"old version: {old.version}", file=stdout)
            if old.changelog:
                print(f"old changelog: {old.changelog}", file=stdout)
            backend.update(target)
            print("::endgroup::", file=stdout)
            new = backend.metadata(target)
            summary.write(summary_row(target, old, new))
        summary.write("\nGenerated by GitHub Actions.\n")
    print(f"Wrote package update summary: {summary_file}", file=stdout)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Update selected flake packages and write a changelog-linked Markdown summary."
        )
    )
    parser.add_argument("--summary-file", type=Path)
    parser.add_argument("--targets-file", type=Path)
    parser.add_argument("--target")
    parser.add_argument("--list-targets", action="store_true")
    return parser


def main(cli_arguments: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(cli_arguments)
    try:
        repo_root = find_repo_root(Path.cwd())
        targets_file = arguments.targets_file or Path(
            os.environ.get(
                "PACKAGE_UPDATE_TARGETS_FILE",
                repo_root / "apps/package-updates/targets.json",
            )
        )
        targets = load_targets(targets_file)
        if arguments.list_targets:
            for target in targets.targets:
                print(f"{target.attr}\t{target.system}")
            return 0
        summary_file = arguments.summary_file or Path(
            os.environ.get(
                "PACKAGE_UPDATE_SUMMARY_FILE",
                repo_root / "package-update-summary.md",
            )
        )
        selected = selected_targets(targets, arguments.target)
        backend = CommandPackageBackend(repo_root, ToolPaths.from_environment(), SubprocessRunner())
        update_packages(selected, summary_file, backend, sys.stdout)
    except (OSError, UpdateError, ValidationError) as error:
        return print_error(error, sys.stderr)
    return 0
