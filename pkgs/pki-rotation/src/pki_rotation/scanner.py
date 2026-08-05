from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from cryptography import x509
from cryptography.x509.oid import NameOID
from sops_tools.errors import ToolError
from sops_tools.model import JsonValue, KeyPath, value_at
from sops_tools.secrets import load_yaml

from .inventory import CertificateSpecSource
from .models import (
    CertificateInventory,
    CertificateRecord,
    CertificateSpec,
    ParsedCertificate,
    SourceKind,
)


class Clock(Protocol):
    def now(self) -> datetime: ...


@dataclass(frozen=True)
class SystemClock:
    def now(self) -> datetime:
        return datetime.now(UTC)


def _common_name(name: x509.Name) -> str:
    attributes = name.get_attributes_for_oid(NameOID.COMMON_NAME)
    return str(attributes[0].value) if attributes else ""


def parse_certificate(value: str) -> ParsedCertificate:
    certificates = x509.load_pem_x509_certificates(value.encode())
    if not certificates:
        raise ValueError("no PEM certificate found")
    certificate = certificates[0]
    return ParsedCertificate(
        common_name=_common_name(certificate.subject),
        issuer_common_name=_common_name(certificate.issuer),
        not_before_timestamp_seconds=certificate.not_valid_before_utc.timestamp(),
        not_after_timestamp_seconds=certificate.not_valid_after_utc.timestamp(),
    )


@dataclass
class CertificateScanner:
    source: CertificateSpecSource
    clock: Clock = field(default_factory=SystemClock)

    def scan(
        self,
        repo_root: Path,
        intermediate_certificate: Path,
        rotation_window_days: int,
    ) -> CertificateInventory:
        documents: dict[Path, JsonValue] = {}
        records = tuple(
            self._scan_spec(spec, documents, rotation_window_days)
            for spec in self.source.specs(repo_root, intermediate_certificate)
        )
        return CertificateInventory(records)

    def _scan_spec(
        self,
        spec: CertificateSpec,
        documents: dict[Path, JsonValue],
        rotation_window_days: int,
    ) -> CertificateRecord:
        certificate_text = self._certificate_text(spec, documents)
        secret_host = spec.secret.host if spec.secret else None
        secret_prefix = spec.secret.prefix if spec.secret else None
        if certificate_text is None or certificate_text.strip() in {"", "REPLACE_ME"}:
            return CertificateRecord(
                host=spec.host,
                category=spec.category,
                cert_name=spec.name,
                source_kind=spec.source_kind,
                secret_host=secret_host,
                secret_prefix=secret_prefix,
            )
        try:
            parsed = parse_certificate(certificate_text)
        except ValueError as error:
            return CertificateRecord(
                host=spec.host,
                category=spec.category,
                cert_name=spec.name,
                source_kind=spec.source_kind,
                secret_host=secret_host,
                secret_prefix=secret_prefix,
                parse_error=str(error),
            )
        seconds_remaining = parsed.not_after_timestamp_seconds - self.clock.now().timestamp()
        return CertificateRecord(
            host=spec.host,
            category=spec.category,
            cert_name=spec.name,
            source_kind=spec.source_kind,
            secret_host=secret_host,
            secret_prefix=secret_prefix,
            parse_success=True,
            rotation_due=seconds_remaining <= rotation_window_days * 86400,
            common_name=parsed.common_name,
            issuer_common_name=parsed.issuer_common_name,
            not_before_timestamp_seconds=parsed.not_before_timestamp_seconds,
            not_after_timestamp_seconds=parsed.not_after_timestamp_seconds,
            days_remaining=seconds_remaining / 86400,
        )

    @staticmethod
    def _certificate_text(
        spec: CertificateSpec,
        documents: dict[Path, JsonValue],
    ) -> str | None:
        if spec.source_kind in {SourceKind.REPOSITORY_FILE, SourceKind.HOST_FILE}:
            if spec.file_path is None or not spec.file_path.is_file():
                return None
            return spec.file_path.read_text()
        assert spec.secret is not None
        if spec.secret.path not in documents:
            documents[spec.secret.path] = load_yaml(spec.secret.path)
        path = KeyPath.parse(spec.secret.prefix).child(spec.secret.certificate_field)
        try:
            value = value_at(documents[spec.secret.path], path)
        except ToolError:
            return None
        if not isinstance(value, str) or value.startswith("ENC["):
            return None
        return value
