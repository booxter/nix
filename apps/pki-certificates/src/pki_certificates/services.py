from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol

from .issuer import CertificateIssuer
from .models import CertificateCategory, CertificateConfig, IssueResult, RealmAuthorityConfig
from .secrets import CertificateStore

IssueKind = Literal[
    "internal-service", "internal-client", "observability-endpoint", "observability-client"
]


def unique_strings(values: list[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(value for value in values if value))


class CertificateConfigSource(Protocol):
    def realm_authority(self, host: str) -> RealmAuthorityConfig: ...

    def certificate_names(self, host: str, category: CertificateCategory) -> list[str]: ...

    def certificate(
        self, host: str, category: CertificateCategory, name: str
    ) -> CertificateConfig: ...


@dataclass(frozen=True)
class ManagedCertificateService:
    configs: CertificateConfigSource
    issuer: CertificateIssuer
    store: CertificateStore

    def internal_service_names(self, host: str) -> list[str]:
        return self.configs.certificate_names(host, "internal_https_server")

    def internal_client_names(self, host: str) -> list[str]:
        return self.configs.certificate_names(host, "internal_https_client")

    def observability_endpoint_names(self, host: str) -> list[str]:
        return self.configs.certificate_names(host, "observability_endpoint_server")

    def observability_client_names(self, host: str) -> list[str]:
        return self.configs.certificate_names(host, "observability_client")

    def _ca_host(self, host: str, override: str | None) -> str:
        return override or self.configs.realm_authority(host).host_name

    def _issue(
        self,
        host: str,
        category: CertificateCategory,
        name: str,
        kind: IssueKind,
        ca_host: str | None,
    ) -> IssueResult:
        config = self.configs.certificate(host, category, name)
        sans = tuple(config.sans)
        material = self.issuer.issue(self._ca_host(host, ca_host), config.common_name, sans)
        client = category.endswith("_client")
        self.store.write(host, config.secret_prefix, material, client=client)
        return IssueResult(
            kind=kind,
            host=host,
            name=name,
            common_name=config.common_name,
            sans=sans,
            secret_prefix=config.secret_prefix,
            port=config.port,
        )

    def issue_internal_service(
        self, host: str, name: str, ca_host: str | None = None
    ) -> IssueResult:
        return self._issue(host, "internal_https_server", name, "internal-service", ca_host)

    def issue_internal_client(
        self, host: str, name: str, ca_host: str | None = None
    ) -> IssueResult:
        return self._issue(host, "internal_https_client", name, "internal-client", ca_host)

    def issue_observability_endpoint(
        self, host: str, name: str, ca_host: str | None = None
    ) -> IssueResult:
        return self._issue(
            host,
            "observability_endpoint_server",
            name,
            "observability-endpoint",
            ca_host,
        )

    def issue_observability_client(
        self, host: str, name: str, ca_host: str | None = None
    ) -> IssueResult:
        return self._issue(host, "observability_client", name, "observability-client", ca_host)
