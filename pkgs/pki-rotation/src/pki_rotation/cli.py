from __future__ import annotations

import argparse
import os
import sys
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO, cast

from atomic_file_writes import write_text_atomic
from pki_certificates.models import FleetHosts
from pki_certificates.repository import configured_file, discover_repo_root, load_fleet_hosts
from sops_tools.errors import ToolError
from sops_tools.process import SubprocessRunner

from .errors import RotationError
from .github import GitHubPullRequestFactory, PullRequestFactory
from .inventory import NixCertificateSpecSource
from .metrics import certificate_metrics, rotation_metrics
from .models import CertificateInventory, CheckoutRequest, RotationRequest, RotationSummary
from .repository import GitRepositoryFactory, RepositoryFactory, authenticated_git_environment
from .rotation import (
    CertificateRotator,
    ManagedCertificateRotator,
    PkiManagedServiceFactory,
    RotationController,
    Scanner,
    rotation_candidates,
)
from .scanner import CertificateScanner, Clock, SystemClock


DEFAULT_INTERMEDIATE_CERTIFICATE = Path("/var/lib/step-ca/certs/intermediate_ca.crt")
DEFAULT_REPOSITORY_URL = "https://github.com/booxter/nix.git"
DEFAULT_BASE_BRANCH = "master"
DEFAULT_SOPS_AGE_KEY_FILE = Path("/var/lib/sops-nix/key.txt")


@dataclass(frozen=True)
class Application:
    scanner: Scanner
    rotator: CertificateRotator
    clock: Clock
    environment: Mapping[str, str]
    repositories: RepositoryFactory
    pull_requests: PullRequestFactory

    @classmethod
    def discover(cls, environment: Mapping[str, str]) -> Application:
        hosts_path = configured_file(environment, "PKI_ROTATION_HOSTS_FILE")
        query = configured_file(environment, "PKI_ROTATION_QUERY_FILE")
        remote_program = configured_file(environment, "PKI_ROTATION_CERTIFICATE_HELPER")
        hosts: FleetHosts = load_fleet_hosts(hosts_path)
        runner = SubprocessRunner()
        return cls(
            scanner=CertificateScanner(NixCertificateSpecSource(runner, hosts, query)),
            rotator=ManagedCertificateRotator(
                PkiManagedServiceFactory(hosts, query, remote_program)
            ),
            clock=SystemClock(),
            environment=dict(environment),
            repositories=GitRepositoryFactory(),
            pull_requests=GitHubPullRequestFactory(),
        )

    def repository_root(self, configured: Path | None) -> Path:
        if configured is not None:
            root = configured.expanduser().resolve()
            if not (root / "flake.nix").is_file():
                raise RotationError(f"repository root is not a flake checkout: {root}")
            return root
        return discover_repo_root(
            Path.cwd(),
            self.environment.get("PKI_ROTATION_REPO_ROOT"),
        )

    def scan(
        self,
        repo_root: Path,
        intermediate_certificate: Path,
        rotation_window_days: int,
    ) -> CertificateInventory:
        return self.scanner.scan(repo_root, intermediate_certificate, rotation_window_days)

    def export(
        self,
        *,
        repo_root: Path | None,
        repo_url: str,
        base_branch: str,
        intermediate_certificate: Path,
        rotation_window_days: int,
    ) -> str:
        if repo_root is not None:
            return certificate_metrics(
                self.scan(repo_root, intermediate_certificate, rotation_window_days)
            )
        with tempfile.TemporaryDirectory(prefix="pki-status-export-") as temporary:
            worktree = Path(temporary) / "repo"
            repository = self.repositories.create()
            repository.clone(CheckoutRequest(repo_url, base_branch, worktree))
            return certificate_metrics(
                self.scan(worktree, intermediate_certificate, rotation_window_days)
            )

    def dry_run(self, repo_root: Path, request: RotationRequest) -> RotationSummary:
        candidates = rotation_candidates(
            self.scan(
                repo_root,
                request.intermediate_cert_path,
                request.rotation_window_days,
            )
        )
        return RotationSummary(
            success=True,
            dry_run=True,
            branch=request.branch,
            base_branch=request.base_branch,
            run_timestamp_seconds=self.clock.now().timestamp(),
            due_count=len(candidates),
            rotated_count=0,
            candidates=tuple(record.reference() for record in candidates),
        )

    def rotate(self, request: RotationRequest, token_file: Path) -> RotationSummary:
        token = token_file.read_text().strip()
        if not token:
            raise RotationError(f"GitHub token file is empty: {token_file}")
        askpass = configured_file(self.environment, "PKI_ROTATION_GIT_ASKPASS")
        git_environment = authenticated_git_environment(
            self.environment,
            token_file=token_file,
            askpass_program=askpass,
        )
        controller = RotationController(
            scanner=self.scanner,
            repository=self.repositories.create(git_environment),
            pull_requests=self.pull_requests.create(token),
            rotator=self.rotator,
            clock=self.clock,
        )
        return controller.run(request)


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="pki-rotation",
        description="Inspect and rotate repository-managed internal PKI certificates.",
    )
    command.add_argument("--repo-root", type=Path)
    command.add_argument("--rotation-window-days", type=int, default=45)
    command.add_argument(
        "--intermediate-cert-path",
        type=Path,
        default=DEFAULT_INTERMEDIATE_CERTIFICATE,
    )
    command.add_argument(
        "--sops-age-key-file",
        type=Path,
        default=Path(os.environ.get("SOPS_AGE_KEY_FILE", str(DEFAULT_SOPS_AGE_KEY_FILE))),
    )
    modes = command.add_subparsers(dest="command", required=True)
    modes.add_parser("scan", help="print the managed certificate inventory as JSON")

    export = modes.add_parser("export-metrics", help="export certificate status metrics")
    export.add_argument("--output", type=Path)
    export.add_argument("--repo-url", default=DEFAULT_REPOSITORY_URL)
    export.add_argument("--base-branch", default=DEFAULT_BASE_BRANCH)

    rotate = modes.add_parser("rotate", help="rotate due leaf certificates through a PR")
    rotate.add_argument("--dry-run", action="store_true")
    rotate.add_argument("--github-token-file", type=Path)
    rotate.add_argument("--repo-url", default=DEFAULT_REPOSITORY_URL)
    rotate.add_argument("--repo-owner", default="booxter")
    rotate.add_argument("--repo-name", default="nix")
    rotate.add_argument("--branch", default="ci/pki-rotate")
    rotate.add_argument("--base-branch", default=DEFAULT_BASE_BRANCH)
    rotate.add_argument("--commit-user-name", default="PKI Rotation Bot")
    rotate.add_argument("--commit-user-email", default="pki-rotation@home.arpa")
    rotate.add_argument("--metrics-output", type=Path)
    return command


def _rotation_request(arguments: argparse.Namespace) -> RotationRequest:
    return RotationRequest(
        repo_url=cast(str, arguments.repo_url),
        owner=cast(str, arguments.repo_owner),
        repo_name=cast(str, arguments.repo_name),
        branch=cast(str, arguments.branch),
        base_branch=cast(str, arguments.base_branch),
        rotation_window_days=cast(int, arguments.rotation_window_days),
        intermediate_cert_path=cast(Path, arguments.intermediate_cert_path),
        sops_age_key_file=cast(Path | None, arguments.sops_age_key_file),
        commit_user_name=cast(str, arguments.commit_user_name),
        commit_user_email=cast(str, arguments.commit_user_email),
    )


def _failure_summary(arguments: argparse.Namespace, clock: Clock) -> RotationSummary:
    return RotationSummary(
        success=False,
        dry_run=cast(bool, arguments.dry_run),
        branch=cast(str, arguments.branch),
        base_branch=cast(str, arguments.base_branch),
        run_timestamp_seconds=clock.now().timestamp(),
        due_count=0,
        rotated_count=0,
    )


def run(
    argv: Sequence[str] | None = None,
    *,
    application: Application | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    command_parser = parser()
    arguments = command_parser.parse_args(argv)
    current = application or Application.discover(os.environ)
    command = cast(str, arguments.command)
    repo_root_argument = cast(Path | None, arguments.repo_root)
    window = cast(int, arguments.rotation_window_days)
    intermediate = cast(Path, arguments.intermediate_cert_path)
    if command == "scan":
        inventory = current.scan(
            current.repository_root(repo_root_argument),
            intermediate,
            window,
        )
        print(inventory.model_dump_json(indent=2), file=stdout)
        return 0
    if command == "export-metrics":
        repo_root = (
            current.repository_root(repo_root_argument) if repo_root_argument is not None else None
        )
        content = current.export(
            repo_root=repo_root,
            repo_url=cast(str, arguments.repo_url),
            base_branch=cast(str, arguments.base_branch),
            intermediate_certificate=intermediate,
            rotation_window_days=window,
        )
        output = cast(Path | None, arguments.output)
        if output is None:
            stdout.write(content)
        else:
            write_text_atomic(output, content, mode=0o644)
        return 0
    request = _rotation_request(arguments)
    metrics_output = cast(Path | None, arguments.metrics_output)
    try:
        if cast(bool, arguments.dry_run):
            summary = current.dry_run(current.repository_root(repo_root_argument), request)
        else:
            token_file = cast(Path | None, arguments.github_token_file)
            if token_file is None:
                command_parser.error("--github-token-file is required unless --dry-run is used")
            summary = current.rotate(request, token_file)
    except Exception:
        if metrics_output is not None:
            try:
                write_text_atomic(
                    metrics_output,
                    rotation_metrics(_failure_summary(arguments, current.clock)),
                    mode=0o644,
                )
            except OSError as error:
                print(f"failed to write PKI rotation failure metrics: {error}", file=stderr)
        raise
    if metrics_output is not None:
        write_text_atomic(metrics_output, rotation_metrics(summary), mode=0o644)
    print(summary.model_dump_json(indent=2), file=stdout)
    return 0


def main() -> int:
    try:
        return run()
    except (OSError, RotationError, ToolError) as error:
        print(error, file=sys.stderr)
        return 1
