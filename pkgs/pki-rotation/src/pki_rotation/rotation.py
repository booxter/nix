from __future__ import annotations

import os
import platform
import socket
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from pki_certificates.issuer import RemoteCertificateIssuer
from pki_certificates.models import FleetHosts
from pki_certificates.repository import NixConfigSource
from pki_certificates.secrets import SopsCertificateStore
from pki_certificates.services import ManagedCertificateService
from sops_tools.process import SubprocessRunner
from sops_tools.repository import RuntimeEnvironment

from .errors import RotationError
from .github import PullRequests
from .models import (
    CertificateCategory,
    CertificateInventory,
    CertificateRecord,
    CertificateReference,
    CheckoutRequest,
    RotationRequest,
    RotationSummary,
)
from .repository import Repository
from .scanner import Clock


class Scanner(Protocol):
    def scan(
        self,
        repo_root: Path,
        intermediate_certificate: Path,
        rotation_window_days: int,
    ) -> CertificateInventory: ...


class CertificateRotator(Protocol):
    def rotate(
        self,
        records: tuple[CertificateRecord, ...],
        *,
        repo_root: Path,
        sops_age_key_file: Path | None,
    ) -> tuple[CertificateReference, ...]: ...


class ManagedServiceFactory(Protocol):
    def create(
        self,
        repo_root: Path,
        sops_age_key_file: Path | None,
    ) -> ManagedCertificateService: ...


@dataclass(frozen=True)
class PkiManagedServiceFactory:
    hosts: FleetHosts
    query: Path
    remote_program: Path

    def create(
        self,
        repo_root: Path,
        sops_age_key_file: Path | None,
    ) -> ManagedCertificateService:
        values = dict(os.environ)
        if sops_age_key_file is not None:
            values["SOPS_AGE_KEY_FILE"] = str(sops_age_key_file)
        runner = SubprocessRunner()
        runtime = RuntimeEnvironment(
            repo_root=repo_root,
            home=Path(values.get("HOME", str(Path.home()))),
            config_home=Path(values.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))),
            system_name=platform.system(),
            hostname=socket.gethostname().split(".", maxsplit=1)[0],
            values=values,
        )
        return ManagedCertificateService(
            NixConfigSource(runner, repo_root, self.hosts, self.query),
            RemoteCertificateIssuer(runner, repo_root, self.hosts, True, self.remote_program),
            SopsCertificateStore(runtime, self.hosts),
        )


@dataclass(frozen=True)
class ManagedCertificateRotator:
    services: ManagedServiceFactory
    ca_host: str = "pki"

    def rotate(
        self,
        records: tuple[CertificateRecord, ...],
        *,
        repo_root: Path,
        sops_age_key_file: Path | None,
    ) -> tuple[CertificateReference, ...]:
        service = self.services.create(repo_root, sops_age_key_file)
        for record in records:
            if record.category is CertificateCategory.INTERNAL_HTTPS_SERVER:
                service.issue_internal_service(record.host, record.cert_name, self.ca_host)
            elif record.category in {
                CertificateCategory.INTERNAL_HTTPS_CLIENT,
                CertificateCategory.EXTERNAL_SERVICE_CLIENT,
            }:
                service.issue_internal_client(record.host, record.cert_name, self.ca_host)
            elif record.category is CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER:
                service.issue_observability_endpoint(record.host, record.cert_name, self.ca_host)
            elif record.category is CertificateCategory.OBSERVABILITY_CLIENT:
                service.issue_observability_client(record.host, record.cert_name, self.ca_host)
            else:
                raise RotationError(f"unsupported rotation category: {record.category.value}")
        return tuple(record.reference() for record in records)


def rotation_candidates(inventory: CertificateInventory) -> tuple[CertificateRecord, ...]:
    return tuple(
        record
        for record in inventory.root
        if record.category is not CertificateCategory.CA and record.rotation_due
    )


def _expiry(record: CertificateRecord) -> str:
    if not record.parse_success or record.not_after_timestamp_seconds is None:
        return "unparsable"
    return datetime.fromtimestamp(record.not_after_timestamp_seconds, tz=UTC).date().isoformat()


def pull_request_body(
    rotated: tuple[CertificateReference, ...],
    refreshed: CertificateInventory,
    *,
    rotation_window_days: int,
) -> str:
    records = {record.reference(): record for record in refreshed.root}
    descriptions = ", ".join(
        f"`{item.host}/{item.category.value}/{item.cert_name}` (expires {_expiry(records[item])})"
        for item in rotated
    )
    return (
        f"- Rotated {len(rotated)} managed internal PKI leaf certificate(s).\n"
        f"- Rotation window: {rotation_window_days} days; leaf lifetime: 180 days.\n"
        f"- Certificates: {descriptions}.\n"
    )


@dataclass(frozen=True)
class RotationController:
    scanner: Scanner
    repository: Repository
    pull_requests: PullRequests
    rotator: CertificateRotator
    clock: Clock

    def run(self, request: RotationRequest) -> RotationSummary:
        started = self.clock.now().timestamp()
        open_pull = self.pull_requests.find_open(
            request.owner,
            request.repo_name,
            branch=request.branch,
            base_branch=request.base_branch,
        )
        with tempfile.TemporaryDirectory(prefix="pki-rotation-") as temporary:
            worktree = Path(temporary) / "repo"
            self.repository.clone(
                CheckoutRequest(
                    request.repo_url,
                    request.branch if open_pull else request.base_branch,
                    worktree,
                )
            )
            if open_pull is None:
                self.repository.create_branch(worktree, request.branch)
            before = self.scanner.scan(
                worktree,
                request.intermediate_cert_path,
                request.rotation_window_days,
            )
            candidates = rotation_candidates(before)
            rotated = self.rotator.rotate(
                candidates,
                repo_root=worktree,
                sops_age_key_file=request.sops_age_key_file,
            )
            after = self.scanner.scan(
                worktree,
                request.intermediate_cert_path,
                request.rotation_window_days,
            )
            pull = open_pull
            if rotated and self.repository.has_secret_changes(worktree):
                self.repository.commit_secrets(
                    worktree,
                    author_name=request.commit_user_name,
                    author_email=request.commit_user_email,
                )
                self.repository.push_branch(worktree, request.branch)
                if pull is None:
                    pull = self.pull_requests.create(
                        request.owner,
                        request.repo_name,
                        branch=request.branch,
                        base_branch=request.base_branch,
                        title="chore: rotate internal PKI leaf certs",
                        body=pull_request_body(
                            rotated,
                            after,
                            rotation_window_days=request.rotation_window_days,
                        ),
                    )
            return RotationSummary(
                success=True,
                dry_run=False,
                branch=request.branch,
                base_branch=request.base_branch,
                run_timestamp_seconds=started,
                due_count=len(candidates),
                rotated_count=len(rotated),
                pr_url=pull.url if pull else None,
                candidates=tuple(record.reference() for record in candidates),
                rotated=rotated,
            )
