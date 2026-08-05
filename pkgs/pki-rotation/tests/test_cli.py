from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, field
from io import StringIO
from pathlib import Path

import pytest

from pki_rotation.cli import Application, run
from pki_rotation.errors import RotationError
from pki_rotation.models import (
    CertificateCategory,
    CertificateInventory,
    CertificateRecord,
    CertificateReference,
    CheckoutRequest,
    PullRequest,
    RotationRequest,
    SourceKind,
)
from pki_rotation.scanner import SystemClock


def due_inventory() -> CertificateInventory:
    return CertificateInventory(
        (
            CertificateRecord(
                host="host",
                category=CertificateCategory.INTERNAL_HTTPS_SERVER,
                cert_name="web",
                source_kind=SourceKind.REPOSITORY_SECRET,
                rotation_due=True,
            ),
        )
    )


@dataclass
class StaticScanner:
    inventory: CertificateInventory = field(default_factory=due_inventory)
    roots: list[Path] = field(default_factory=list)

    def scan(self, repo_root: Path, intermediate: Path, window: int) -> CertificateInventory:
        self.roots.append(repo_root)
        return self.inventory


@dataclass
class StaticRotator:
    calls: int = 0

    def rotate(
        self,
        records: tuple[CertificateRecord, ...],
        *,
        repo_root: Path,
        sops_age_key_file: Path | None,
    ) -> tuple[CertificateReference, ...]:
        self.calls += 1
        return tuple(record.reference() for record in records)


@dataclass
class RecordingRepository:
    fail_clone: bool = False
    changed: bool = True
    clones: list[CheckoutRequest] = field(default_factory=list)
    commits: int = 0

    def clone(self, request: CheckoutRequest) -> None:
        if self.fail_clone:
            raise RotationError("clone failed")
        self.clones.append(request)

    def create_branch(self, repo_root: Path, branch: str) -> None:
        pass

    def has_secret_changes(self, repo_root: Path) -> bool:
        return self.changed

    def commit_secrets(self, repo_root: Path, *, author_name: str, author_email: str) -> None:
        self.commits += 1

    def push_branch(self, repo_root: Path, branch: str) -> None:
        pass


@dataclass
class RecordingRepositoryFactory:
    repository: RecordingRepository
    environments: list[Mapping[str, str] | None] = field(default_factory=list)

    def create(self, environment: Mapping[str, str] | None = None) -> RecordingRepository:
        self.environments.append(environment)
        return self.repository


@dataclass
class RecordingPullRequests:
    created: int = 0

    def find_open(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
    ) -> PullRequest | None:
        return None

    def create(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
        title: str,
        body: str,
    ) -> PullRequest:
        self.created += 1
        return PullRequest("https://github.com/owner/repo/pull/1")


@dataclass
class RecordingPullRequestFactory:
    pull_requests: RecordingPullRequests
    tokens: list[str] = field(default_factory=list)

    def create(self, token: str) -> RecordingPullRequests:
        self.tokens.append(token)
        return self.pull_requests


def application(
    repository: RecordingRepository | None = None,
) -> tuple[Application, RecordingRepositoryFactory, RecordingPullRequestFactory]:
    repository_factory = RecordingRepositoryFactory(repository or RecordingRepository())
    pull_factory = RecordingPullRequestFactory(RecordingPullRequests())
    app = Application(
        scanner=StaticScanner(),
        rotator=StaticRotator(),
        clock=SystemClock(),
        environment={"PKI_ROTATION_GIT_ASKPASS": "/nix/store/askpass"},
        repositories=repository_factory,
        pull_requests=pull_factory,
    )
    return app, repository_factory, pull_factory


def flake_root(tmp_path: Path) -> Path:
    (tmp_path / "flake.nix").write_text("{}")
    return tmp_path


def test_scan_and_export_dispatch_use_typed_models(tmp_path: Path) -> None:
    root = flake_root(tmp_path)
    app, _, _ = application()
    scan_output = StringIO()

    assert run(["--repo-root", str(root), "scan"], application=app, stdout=scan_output) == 0
    assert json.loads(scan_output.getvalue())[0]["cert_name"] == "web"

    metrics = tmp_path / "metrics" / "pki.prom"
    assert (
        run(
            ["--repo-root", str(root), "export-metrics", "--output", str(metrics)],
            application=app,
        )
        == 0
    )
    assert "host_observability_pki_cert_expected" in metrics.read_text()
    assert metrics.stat().st_mode & 0o777 == 0o644


def test_export_clones_when_no_repository_root_is_supplied() -> None:
    app, repositories, _ = application()

    content = app.export(
        repo_root=None,
        repo_url="https://github.com/owner/repo.git",
        base_branch="master",
        intermediate_certificate=Path("/intermediate.crt"),
        rotation_window_days=45,
    )

    assert "host_observability_pki_cert_expected" in content
    assert repositories.repository.clones[0].branch == "master"
    assert repositories.environments == [None]


def test_rotate_dry_run_writes_summary_and_metrics(tmp_path: Path) -> None:
    root = flake_root(tmp_path)
    metrics = tmp_path / "rotation.prom"
    output = StringIO()
    app, _, _ = application()

    assert (
        run(
            [
                "--repo-root",
                str(root),
                "rotate",
                "--dry-run",
                "--metrics-output",
                str(metrics),
            ],
            application=app,
            stdout=output,
        )
        == 0
    )

    assert json.loads(output.getvalue())["due_count"] == 1
    assert "host_observability_pki_rotation_last_success" in metrics.read_text()


def test_authenticated_rotate_uses_factories_and_creates_pull_request(tmp_path: Path) -> None:
    token = tmp_path / "token"
    token.write_text("github-token\n")
    output = StringIO()
    app, repositories, pulls = application()

    assert (
        run(
            ["rotate", "--github-token-file", str(token)],
            application=app,
            stdout=output,
        )
        == 0
    )

    assert json.loads(output.getvalue())["pr_url"].endswith("/pull/1")
    assert pulls.tokens == ["github-token"]
    environment = repositories.environments[0]
    assert environment is not None
    assert environment["PKI_ROTATION_GITHUB_TOKEN_FILE"] == str(token.resolve())
    assert repositories.repository.commits == 1


def test_rotation_failure_writes_failure_metric(tmp_path: Path) -> None:
    token = tmp_path / "token"
    token.write_text("github-token")
    metrics = tmp_path / "rotation.prom"
    app, _, _ = application(RecordingRepository(fail_clone=True))

    with pytest.raises(RotationError, match="clone failed"):
        run(
            [
                "rotate",
                "--github-token-file",
                str(token),
                "--metrics-output",
                str(metrics),
            ],
            application=app,
        )

    assert "host_observability_pki_rotation_last_success" in metrics.read_text()
    assert " 0.0" in metrics.read_text()


def test_repository_root_rejects_non_flake_and_empty_token(tmp_path: Path) -> None:
    app, _, _ = application()
    with pytest.raises(RotationError, match="not a flake checkout"):
        app.repository_root(tmp_path)

    token = tmp_path / "token"
    token.write_text("\n")
    with pytest.raises(RotationError, match="token file is empty"):
        app.rotate(
            request=RotationRequest(
                repo_url="url",
                owner="owner",
                repo_name="repo",
                branch="branch",
                base_branch="master",
                rotation_window_days=45,
                intermediate_cert_path=Path("/intermediate"),
                sops_age_key_file=None,
                commit_user_name="Bot",
                commit_user_email="bot@example.com",
            ),
            token_file=token,
        )
