from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pki_certificates.models import FleetHosts, HostCertificateConfig
from pki_certificates.repository import NixConfigSource
from sops_tools.process import ProcessRunner

from .models import (
    CertificateCategory,
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
        pki = self.hosts.root["pki"]
        specs = [
            CertificateSpec(
                host=pki.runtime_host,
                category=CertificateCategory.CA,
                name="root",
                source_kind=SourceKind.REPOSITORY_FILE,
                file_path=(
                    self.repo_root
                    / "common"
                    / "_mixins"
                    / "internal-pki"
                    / "home-internal-pki-root-ca.crt"
                ),
            ),
            CertificateSpec(
                host=pki.runtime_host,
                category=CertificateCategory.CA,
                name="intermediate",
                source_kind=SourceKind.HOST_FILE,
                file_path=self.intermediate_certificate,
            ),
        ]
        for host, facts in sorted(self.hosts.root.items()):
            secret_path = self.repo_root / "secrets" / facts.secret_domain / f"{host}.yaml"
            if not secret_path.is_file():
                continue
            specs.extend(self._host_specs(host, secret_path, self.configs.certificate_config(host)))
        return tuple(sorted(specs, key=lambda spec: (spec.category.value, spec.host, spec.name)))

    @staticmethod
    def _secret_spec(
        host: str,
        secret_path: Path,
        category: CertificateCategory,
        name: str,
        prefix: str,
        field: str,
    ) -> CertificateSpec:
        return CertificateSpec(
            host=host,
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
        specs: list[CertificateSpec] = []
        proxmox_prefix = config.proxmox_api.secret_prefix if config.proxmox_api else None
        for name, service in sorted(config.internal_services.items()):
            duplicate_proxmox = name == "proxmox" and service.secret_prefix == proxmox_prefix
            if service.enable and not duplicate_proxmox:
                specs.append(
                    self._secret_spec(
                        host,
                        secret_path,
                        CertificateCategory.INTERNAL_HTTPS_SERVER,
                        name,
                        service.secret_prefix,
                        "server_crt_unencrypted",
                    )
                )
        if config.proxmox_api is not None:
            specs.append(
                self._secret_spec(
                    host,
                    secret_path,
                    CertificateCategory.INTERNAL_HTTPS_SERVER,
                    "proxmox-api",
                    config.proxmox_api.secret_prefix,
                    "server_crt_unencrypted",
                )
            )
        for category, clients in (
            (CertificateCategory.INTERNAL_HTTPS_CLIENT, config.internal_clients),
            (CertificateCategory.EXTERNAL_SERVICE_CLIENT, config.external_clients),
            (CertificateCategory.OBSERVABILITY_CLIENT, config.observability_clients),
        ):
            for name, client in sorted(clients.items()):
                if client.enable:
                    specs.append(
                        self._secret_spec(
                            host,
                            secret_path,
                            category,
                            name,
                            client.secret_prefix,
                            "client_crt_unencrypted",
                        )
                    )
        endpoints = dict(config.observability_endpoints)
        if config.node_exporter is not None:
            endpoints["node_exporter"] = config.node_exporter
        for name, endpoint in sorted(endpoints.items()):
            if endpoint.enable:
                specs.append(
                    self._secret_spec(
                        host,
                        secret_path,
                        CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER,
                        name,
                        endpoint.secret_prefix,
                        "server_crt_unencrypted",
                    )
                )
        return specs


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
