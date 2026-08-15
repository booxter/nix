from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pydantic import ValidationError
from pki_certificates.models import PkiInventory
from pki_certificates.repository import InventorySource
from sops_tools.errors import ToolError

from .models import (
    CertificateCategory,
    CertificateSpec,
    SecretLocation,
    SourceKind,
)


class CertificateSpecSource(Protocol):
    def specs(
        self, repo_root: Path, intermediate_certificate: Path
    ) -> tuple[CertificateSpec, ...]: ...


@dataclass(frozen=True)
class InventoryCertificateSpecSource:
    inventory: PkiInventory

    def specs(self, repo_root: Path, intermediate_certificate: Path) -> tuple[CertificateSpec, ...]:
        authority = self.inventory.authority
        specs = [
            CertificateSpec(
                host=authority.host_name,
                realm=authority.realm,
                category=CertificateCategory.CA,
                name="root",
                source_kind=SourceKind.REPOSITORY_FILE,
                file_path=Path(authority.root_ca_certificate),
            ),
            CertificateSpec(
                host=authority.host_name,
                realm=authority.realm,
                category=CertificateCategory.CA,
                name="intermediate",
                source_kind=SourceKind.HOST_FILE,
                file_path=intermediate_certificate,
            ),
        ]
        specs.extend(
            CertificateSpec(
                host=certificate.host,
                realm=certificate.realm,
                category=CertificateCategory(certificate.category),
                name=certificate.name,
                source_kind=SourceKind.REPOSITORY_SECRET,
                secret=SecretLocation(
                    certificate.host,
                    repo_root / certificate.secret_path,
                    certificate.secret_prefix,
                    certificate.certificate_field,
                ),
            )
            for certificate in self.inventory.certificates
        )
        return tuple(sorted(specs, key=lambda spec: (spec.category.value, spec.host, spec.name)))


@dataclass(frozen=True)
class NixCertificateSpecSource:
    inventories: InventorySource

    def specs(self, repo_root: Path, intermediate_certificate: Path) -> tuple[CertificateSpec, ...]:
        return InventoryCertificateSpecSource(self.inventories.inventory(repo_root)).specs(
            repo_root,
            intermediate_certificate,
        )


def load_inventory(path: Path) -> PkiInventory:
    try:
        return PkiInventory.model_validate_json(path.read_bytes())
    except (OSError, ValidationError) as error:
        raise ToolError(f"invalid PKI certificate inventory {path}: {error}") from error
