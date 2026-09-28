from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

from github import Auth, Github

from .audit import Auditor
from .models import Configuration, ExternalComparison, RiskReport
from .nix import NixClient
from .process import CommandRunner, RiskError, SubprocessRunner
from .report import render
from .tracker import (
    GitHubIssueResolver,
    HttpTransport,
    TrackerCache,
    TrackerClient,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Show vulnerability and maintainer risks in NixOS and nix-darwin runtime closures."
        )
    )
    result.add_argument("configurations", nargs="*", metavar="CONFIG")
    result.add_argument("--all", action="store_true", help="scan every configuration in the flake")
    result.add_argument("--flake", default=".", help="flake reference (default: current directory)")
    result.add_argument(
        "--no-build",
        action="store_true",
        help="do not realize configurations; requires their output closures to already exist",
    )
    result.add_argument(
        "--no-tracker",
        action="store_true",
        help="skip online NixOS Security Tracker checks",
    )
    result.add_argument(
        "--compare-input",
        action="append",
        dest="comparison_inputs",
        help="flake input containing nixpkgs to compare (repeatable)",
    )
    result.add_argument(
        "--staging",
        action="store_true",
        help="also compare versions with github:NixOS/nixpkgs/staging",
    )
    result.add_argument(
        "--hyperlinks",
        choices=("auto", "always", "never"),
        default="auto",
        help="emit clickable terminal links (default: auto)",
    )
    return result


def _required_path(environment: str, environ: Mapping[str, str]) -> Path:
    value = environ.get(environment)
    if not value:
        raise RiskError(f"{environment} is not set; run this command through the flake app")
    return Path(value)


def _cache_path(environ: Mapping[str, str]) -> Path:
    root = environ.get("XDG_CACHE_HOME")
    if root:
        return Path(root) / "package-risk" / "tracker.json"
    return Path.home() / ".cache" / "package-risk" / "tracker.json"


def select_configurations(
    inventory: list[Configuration], requested: list[str], all_configurations: bool
) -> list[Configuration]:
    if all_configurations and requested:
        raise RiskError("pass configuration names or --all, not both")
    if not all_configurations and not requested:
        raise RiskError("pass at least one configuration name, or use --all")
    if all_configurations:
        return inventory
    by_name: dict[str, list[Configuration]] = {}
    for configuration in inventory:
        by_name.setdefault(configuration.name, []).append(configuration)
    selected: list[Configuration] = []
    for name in requested:
        matches = by_name.get(name, [])
        if not matches:
            raise RiskError(f"configuration not found: {name}")
        if len(matches) > 1:
            raise RiskError(f"configuration name is ambiguous: {name}")
        selected.append(matches[0])
    return selected


def _exit_code(reports: Sequence[RiskReport]) -> int:
    if any(report.vulnerabilities for report in reports):
        return 2
    if any(report.unmaintained for report in reports):
        return 1
    return 0


def run(
    arguments: Sequence[str] | None = None,
    *,
    runner: CommandRunner | None = None,
    environ: Mapping[str, str] | None = None,
) -> int:
    options = parser().parse_args(arguments)
    command_runner = runner or SubprocessRunner()
    process_environment = os.environ if environ is None else environ
    nix = NixClient(
        command_runner,
        inventory_helper=_required_path("PACKAGE_RISK_INVENTORY_NIX", process_environment),
        metadata_helper=_required_path("PACKAGE_RISK_METADATA_NIX", process_environment),
        vulnix=_required_path("PACKAGE_RISK_VULNIX", process_environment),
    )
    inventory = nix.inventory(str(options.flake))
    configurations = select_configurations(
        inventory, list(options.configurations), bool(options.all)
    )
    comparison_inputs = options.comparison_inputs or [
        "nixpkgs",
        "nixpkgs-darwin",
        "nixpkgs-unstable",
    ]
    external = (
        [ExternalComparison(label="staging", flakeRef="github:NixOS/nixpkgs/staging")]
        if options.staging
        else []
    )

    def note(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    transport = HttpTransport(
        token=process_environment.get("PACKAGE_RISK_TRACKER_TOKEN"), note=note
    )
    github_token = process_environment.get("GITHUB_TOKEN") or process_environment.get("GH_TOKEN")
    github = (
        Github(auth=Auth.Token(github_token), timeout=60, per_page=100)
        if github_token
        else Github(timeout=60, per_page=100)
    )
    tracker = TrackerClient(
        transport,
        TrackerCache(_cache_path(process_environment)),
        note=note,
        open_issues=GitHubIssueResolver(github),
    )
    auditor = Auditor(nix, tracker, note)
    try:
        reports = [
            auditor.run(
                str(options.flake),
                configuration,
                build=not options.no_build,
                scan_tracker=not options.no_tracker,
                comparison_inputs=comparison_inputs,
                external_comparisons=external,
            )
            for configuration in configurations
        ]
    finally:
        transport.close()
        github.close()
    hyperlinks = options.hyperlinks == "always" or (
        options.hyperlinks == "auto" and sys.stdout.isatty()
    )
    print("\n\n".join(render(report, hyperlinks=hyperlinks) for report in reports))
    return _exit_code(reports)


def main() -> None:
    try:
        raise SystemExit(run())
    except RiskError as error:
        print(f"risk: {error}", file=sys.stderr)
        raise SystemExit(3) from error
