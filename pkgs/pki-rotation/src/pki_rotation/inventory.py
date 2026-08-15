from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pydantic import ValidationError
from pki_certificates.models import FleetHosts, HostCertificateConfig
from pki_certificates.repository import NixConfigSource
from pki_certificates.services import SECRET_FIELDS
from sops_tools.errors import ToolError
from sops_tools.process import ProcessRunner

from .models import (
    CertificateCategory,
    CertificateManifest,
    CertificateSpec,
    SecretLocation,
    SourceKind,
)


class CertificateConfigSource(Protocol):
    def certificate_config(self, host: str) -> HostCertificateConfig: ...


class CertificateSpecSource(Protocol):
    def specs(
        self, repo_root: Path, intermediate_certificate: Path
    ) -> tuple[CertificateSpec, ...]: ...


@dataclass(frozen=True)
class CertificateInventoryBuilder:
    repo_root: Path
    hosts: FleetHosts
    configs: CertificateConfigSource
    intermediate_certificate: Path

    def specs(self) -> tuple[CertificateSpec, ...]:
        configs = {host: self.configs.certificate_config(host) for host in sorted(self.hosts.root)}
        authorities = {
            config.realm: config.realm_authority
            for host, config in configs.items()
            if config.realm_authority is not None and config.realm_authority.host_name == host
        }
        configured_realms = {config.realm for config in configs.values()}
        missing_realms = sorted(configured_realms - authorities.keys())
        if missing_realms:
            raise ToolError(
                "dynamic PKI scans require a configured authority for every realm; "
                f"missing: {', '.join(missing_realms)}"
            )
        specs: list[CertificateSpec] = []
        for realm, authority in sorted(authorities.items()):
            assert authority is not None
            runtime_host = self.hosts.root[authority.host_name].runtime_host
            specs.extend(
                (
                    CertificateSpec(
                        host=runtime_host,
                        realm=realm,
                        category=CertificateCategory.CA,
                        name="root",
                        source_kind=SourceKind.REPOSITORY_FILE,
                        file_path=Path(authority.root_ca_certificate),
                    ),
                    CertificateSpec(
                        host=runtime_host,
                        realm=realm,
                        category=CertificateCategory.CA,
                        name="intermediate",
                        source_kind=SourceKind.HOST_FILE,
                        file_path=self.intermediate_certificate,
                    ),
                )
            )
        for host, host_entry in sorted(self.hosts.root.items()):
            secret_path = self.repo_root / "secrets" / host_entry.realm / f"{host}.yaml"
            specs.extend(self._host_specs(host, secret_path, configs[host]))
        return tuple(sorted(specs, key=lambda spec: (spec.category.value, spec.host, spec.name)))

    @staticmethod
    def _secret_spec(
        host: str,
        realm: str,
        secret_path: Path,
        category: CertificateCategory,
        name: str,
        prefix: str,
        field: str,
    ) -> CertificateSpec:
        return CertificateSpec(
            host=host,
            realm=realm,
            category=category,
            name=name,
            source_kind=SourceKind.REPOSITORY_SECRET,
            secret=SecretLocation(host, secret_path, prefix, field),
        )

    def _host_specs(
        self,
        host: str,
        secret_path: Path,
        config: HostCertificateConfig,
    ) -> list[CertificateSpec]:
        return [
            self._secret_spec(
                host,
                config.realm,
                secret_path,
                CertificateCategory(certificate.category),
                certificate.name,
                certificate.secret_prefix,
                SECRET_FIELDS[certificate.category][0],
            )
            for certificate in config.certificates
        ]


@dataclass(frozen=True)
class NixCertificateSpecSource:
    runner: ProcessRunner
    hosts: FleetHosts
    query: Path

    def specs(self, repo_root: Path, intermediate_certificate: Path) -> tuple[CertificateSpec, ...]:
        configs = NixConfigSource(self.runner, repo_root, self.hosts, self.query)
        return CertificateInventoryBuilder(
            repo_root,
            self.hosts,
            configs,
            intermediate_certificate,
        ).specs()


def load_certificate_manifest(path: Path) -> CertificateManifest:
    try:
        return CertificateManifest.model_validate_json(path.read_bytes())
    except (OSError, ValidationError) as error:
        raise ToolError(f"invalid PKI certificate inventory manifest {path}: {error}") from error


@dataclass(frozen=True)
class ManifestCertificateSpecSource:
    manifest: CertificateManifest

    def specs(self, repo_root: Path, intermediate_certificate: Path) -> tuple[CertificateSpec, ...]:
        del repo_root
        specs = [entry.spec() for entry in self.manifest.certificates]
        specs.append(
            CertificateSpec(
                host=self.manifest.authority_host,
                realm=self.manifest.realm,
                category=CertificateCategory.CA,
                name="intermediate",
                source_kind=SourceKind.HOST_FILE,
                file_path=intermediate_certificate,
            )
        )
        return tuple(sorted(specs, key=lambda spec: (spec.category.value, spec.host, spec.name)))
