from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, RootModel, model_validator


class CertificateCategory(StrEnum):
    CA = "ca"
    INTERNAL_HTTPS_SERVER = "internal_https_server"
    INTERNAL_HTTPS_CLIENT = "internal_https_client"
    OBSERVABILITY_ENDPOINT_SERVER = "observability_endpoint_server"
    OBSERVABILITY_CLIENT = "observability_client"


class SourceKind(StrEnum):
    REPOSITORY_FILE = "repo_file"
    HOST_FILE = "host_file"
    REPOSITORY_SECRET = "repo_secret"


@dataclass(frozen=True)
class SecretLocation:
    host: str
    path: Path
    prefix: str
    certificate_field: str


@dataclass(frozen=True)
class CertificateSpec:
    host: str
    category: CertificateCategory
    name: str
    source_kind: SourceKind
    file_path: Path | None = None
    secret: SecretLocation | None = None

    def __post_init__(self) -> None:
        if (self.file_path is None) == (self.secret is None):
            raise ValueError("certificate source must have exactly one location")


class ManifestSecretLocation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    host: str
    path: Path
    prefix: str
    certificate_field: str

    def location(self) -> SecretLocation:
        return SecretLocation(
            host=self.host,
            path=self.path,
            prefix=self.prefix,
            certificate_field=self.certificate_field,
        )


class ManifestCertificateSpec(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    host: str
    category: CertificateCategory
    name: str
    source_kind: SourceKind
    file_path: Path | None = None
    secret: ManifestSecretLocation | None = None

    @model_validator(mode="after")
    def validate_location(self) -> ManifestCertificateSpec:
        if (self.file_path is None) == (self.secret is None):
            raise ValueError("certificate source must have exactly one location")
        if self.source_kind is SourceKind.REPOSITORY_SECRET and self.secret is None:
            raise ValueError("repository secret source requires a secret location")
        if self.source_kind is not SourceKind.REPOSITORY_SECRET and self.file_path is None:
            raise ValueError("file source requires a file path")
        return self

    def spec(self) -> CertificateSpec:
        return CertificateSpec(
            host=self.host,
            category=self.category,
            name=self.name,
            source_kind=self.source_kind,
            file_path=self.file_path,
            secret=self.secret.location() if self.secret else None,
        )


class CertificateManifest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    authority_host: str
    certificates: tuple[ManifestCertificateSpec, ...]


@dataclass(frozen=True)
class ParsedCertificate:
    common_name: str
    issuer_common_name: str
    not_before_timestamp_seconds: float
    not_after_timestamp_seconds: float


class CertificateRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    host: str
    category: CertificateCategory
    cert_name: str
    source_kind: SourceKind
    secret_host: str | None = None
    secret_prefix: str | None = None
    parse_success: bool = False
    rotation_due: bool = True
    parse_error: str | None = None
    common_name: str = ""
    issuer_common_name: str = ""
    not_before_timestamp_seconds: float | None = None
    not_after_timestamp_seconds: float | None = None
    days_remaining: float | None = None

    def reference(self) -> CertificateReference:
        return CertificateReference(
            host=self.host,
            category=self.category,
            cert_name=self.cert_name,
        )


class CertificateInventory(RootModel[tuple[CertificateRecord, ...]]):
    model_config = ConfigDict(frozen=True, strict=True)


class CertificateReference(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    host: str
    category: CertificateCategory
    cert_name: str


class RotationSummary(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    success: bool
    dry_run: bool
    branch: str
    base_branch: str
    run_timestamp_seconds: float
    due_count: int = Field(ge=0)
    rotated_count: int = Field(ge=0)
    pr_url: str | None = None
    candidates: tuple[CertificateReference, ...] = ()
    rotated: tuple[CertificateReference, ...] = ()


@dataclass(frozen=True)
class PullRequest:
    url: str


@dataclass(frozen=True)
class RotationRequest:
    repo_url: str
    owner: str
    repo_name: str
    branch: str
    base_branch: str
    rotation_window_days: int
    intermediate_cert_path: Path
    sops_age_key_file: Path | None
    commit_user_name: str
    commit_user_email: str


@dataclass(frozen=True)
class CheckoutRequest:
    repo_url: str
    branch: str
    target: Path
