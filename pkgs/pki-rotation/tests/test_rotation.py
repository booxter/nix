from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import pytest

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
from pki_rotation.rotation import (
    ManagedCertificateRotator,
    RotationController,
    pull_request_body,
    rotation_candidates,
)


def record(
    category: CertificateCategory = CertificateCategory.INTERNAL_HTTPS_SERVER,
    *,
    due: bool = True,
    expires: float = 1_800_000_000.0,
) -> CertificateRecord:
    return CertificateRecord(
        host="host",
        category=category,
        cert_name="web",
        source_kind=SourceKind.REPOSITORY_SECRET,
        parse_success=True,
        rotation_due=due,
        not_before_timestamp_seconds=1_700_000_000.0,
        not_after_timestamp_seconds=expires,
        days_remaining=10.0,
    )


@dataclass(frozen=True)
class FixedClock:
    def now(self) -> datetime:
        return datetime(2026, 1, 1, tzinfo=UTC)


@dataclass
class SequenceScanner:
    inventories: list[CertificateInventory]
    roots: list[Path] = field(default_factory=list)

    def scan(self, repo_root: Path, intermediate: Path, window: int) -> CertificateInventory:
        self.roots.append(repo_root)
        return self.inventories.pop(0)


@dataclass
class RecordingRepository:
    changed: bool = True
    cloned: CheckoutRequest | None = None
    created: list[str] = field(default_factory=list)
    committed: int = 0
    pushed: list[str] = field(default_factory=list)

    def clone(self, request: CheckoutRequest) -> None:
        self.cloned = request

    def create_branch(self, repo_root: Path, branch: str) -> None:
        self.created.append(branch)

    def has_secret_changes(self, repo_root: Path) -> bool:
        return self.changed

    def commit_secrets(self, repo_root: Path, *, author_name: str, author_email: str) -> None:
        self.committed += 1

    def push_branch(self, repo_root: Path, branch: str) -> None:
        self.pushed.append(branch)


@dataclass
class RecordingPullRequests:
    open_pull: PullRequest | None = None
    created: list[tuple[str, str, str]] = field(default_factory=list)

    def find_open(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
    ) -> PullRequest | None:
        return self.open_pull

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
        self.created.append((title, branch, body))
        return PullRequest("https://github.com/owner/repo/pull/1")


@dataclass
class RecordingRotator:
    records: list[tuple[CertificateRecord, ...]] = field(default_factory=list)

    def rotate(
        self,
        records: tuple[CertificateRecord, ...],
        *,
        repo_root: Path,
        sops_age_key_file: Path | None,
    ) -> tuple[CertificateReference, ...]:
        self.records.append(records)
        return tuple(item.reference() for item in records)


def request() -> RotationRequest:
    return RotationRequest(
        repo_url="https://github.com/owner/repo.git",
        owner="owner",
        repo_name="repo",
        branch="ci/pki-rotate",
        base_branch="master",
        rotation_window_days=45,
        intermediate_cert_path=Path("/intermediate.crt"),
        sops_age_key_file=Path("/age-key"),
        commit_user_name="PKI Bot",
        commit_user_email="pki@example.com",
    )


def test_controller_rotates_commits_pushes_and_creates_pull_request() -> None:
    before = CertificateInventory((record(), record(due=False)))
    after = CertificateInventory((record(due=False),))
    scanner = SequenceScanner([before, after])
    repository = RecordingRepository()
    pulls = RecordingPullRequests()
    rotator = RecordingRotator()

    summary = RotationController(
        scanner,
        repository,
        pulls,
        rotator,
        FixedClock(),
    ).run(request())

    assert repository.cloned is not None
    assert repository.cloned.branch == "master"
    assert repository.created == ["ci/pki-rotate"]
    assert repository.committed == 1
    assert repository.pushed == ["ci/pki-rotate"]
    assert len(pulls.created) == 1
    assert summary.due_count == 1
    assert summary.rotated_count == 1
    assert summary.pr_url == "https://github.com/owner/repo/pull/1"


def test_controller_reuses_open_pull_branch_without_recreating_it() -> None:
    pull = PullRequest("https://github.com/owner/repo/pull/7")
    repository = RecordingRepository(changed=False)
    pulls = RecordingPullRequests(open_pull=pull)
    inventory = CertificateInventory(())

    summary = RotationController(
        SequenceScanner([inventory, inventory]),
        repository,
        pulls,
        RecordingRotator(),
        FixedClock(),
    ).run(request())

    assert repository.cloned is not None
    assert repository.cloned.branch == "ci/pki-rotate"
    assert repository.created == []
    assert summary.pr_url == pull.url


def test_candidates_exclude_ca_and_not_due_certificates() -> None:
    inventory = CertificateInventory(
        (
            record(CertificateCategory.CA),
            record(due=False),
            record(CertificateCategory.OBSERVABILITY_CLIENT),
        )
    )

    assert rotation_candidates(inventory) == (record(CertificateCategory.OBSERVABILITY_CLIENT),)


def test_pull_request_body_obeys_terse_repository_style() -> None:
    item = record().reference()
    body = pull_request_body((item,), CertificateInventory((record(),)), rotation_window_days=45)

    assert body.count("\n") == 3
    assert not any(line.startswith("#") for line in body.splitlines())
    assert "host/internal_https_server/web" in body


@dataclass
class RecordingManagedService:
    calls: list[tuple[str, str]] = field(default_factory=list)

    def issue_internal_service(self, host: str, name: str, ca_host: str) -> None:
        self.calls.append(("service", name))

    def issue_internal_client(self, host: str, name: str, ca_host: str) -> None:
        self.calls.append(("client", name))

    def issue_observability_endpoint(self, host: str, name: str, ca_host: str) -> None:
        self.calls.append(("endpoint", name))

    def issue_observability_client(self, host: str, name: str, ca_host: str) -> None:
        self.calls.append(("observability-client", name))


@dataclass
class StaticServiceFactory:
    service: RecordingManagedService

    def create(self, repo_root: Path, sops_age_key_file: Path | None):
        return self.service


def test_managed_rotator_dispatches_each_leaf_category() -> None:
    service = RecordingManagedService()
    records = tuple(
        record(category)
        for category in (
            CertificateCategory.INTERNAL_HTTPS_SERVER,
            CertificateCategory.INTERNAL_HTTPS_CLIENT,
            CertificateCategory.EXTERNAL_SERVICE_CLIENT,
            CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER,
            CertificateCategory.OBSERVABILITY_CLIENT,
        )
    )

    ManagedCertificateRotator(StaticServiceFactory(service)).rotate(
        records,
        repo_root=Path("/repo"),
        sops_age_key_file=None,
    )

    assert service.calls == [
        ("service", "web"),
        ("client", "web"),
        ("client", "web"),
        ("endpoint", "web"),
        ("observability-client", "web"),
    ]


def test_managed_rotator_rejects_ca_rotation() -> None:
    with pytest.raises(RotationError, match="unsupported rotation category: ca"):
        ManagedCertificateRotator(StaticServiceFactory(RecordingManagedService())).rotate(
            (record(CertificateCategory.CA),),
            repo_root=Path("/repo"),
            sops_age_key_file=None,
        )
