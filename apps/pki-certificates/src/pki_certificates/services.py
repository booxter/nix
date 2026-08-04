from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from sops_tools.errors import ToolError

from .issuer import CertificateIssuer
from .models import (
    CertificateClientConfig,
    HostIdentity,
    InternalServiceConfig,
    IssueResult,
    ObservabilityEndpointConfig,
)
from .secrets import CertificateStore


class CertificateConfigSource(Protocol):
    def internal_service_names(self, host: str) -> list[str]: ...

    def internal_service(self, host: str, name: str) -> InternalServiceConfig: ...

    def internal_client_names(self, host: str) -> list[str]: ...

    def internal_client(self, host: str, name: str) -> CertificateClientConfig: ...

    def observability_endpoint_names(self, host: str) -> list[str]: ...

    def observability_endpoint(self, host: str, name: str) -> ObservabilityEndpointConfig: ...

    def observability_client_names(self, host: str) -> list[str]: ...

    def observability_client(self, host: str, name: str) -> CertificateClientConfig: ...

    def host_identity(self, host: str) -> HostIdentity: ...


def unique_strings(values: list[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(value for value in values if value))


@dataclass(frozen=True)
class ManagedCertificateService:
    configs: CertificateConfigSource
    issuer: CertificateIssuer
    store: CertificateStore

    def internal_service_names(self, host: str) -> list[str]:
        return self.configs.internal_service_names(host)

    def internal_client_names(self, host: str) -> list[str]:
        return self.configs.internal_client_names(host)

    def observability_endpoint_names(self, host: str) -> list[str]:
        return self.configs.observability_endpoint_names(host)

    def observability_client_names(self, host: str) -> list[str]:
        return self.configs.observability_client_names(host)

    def issue_internal_service(self, host: str, name: str, ca_host: str) -> IssueResult:
        config = self.configs.internal_service(host, name)
        if not config.enable:
            raise ToolError(f"internal HTTPS service {name} on host {host} is not enabled")
        fallback = [config.server_name, *config.server_aliases]
        if name != "proxmox-api":
            fallback.insert(0, name)
        sans = unique_strings(config.sans or fallback)
        material = self.issuer.issue(ca_host, config.server_name, sans)
        self.store.write(host, config.secret_prefix, material, client=False)
        return IssueResult(
            kind="internal-service",
            host=host,
            name=name,
            common_name=config.server_name,
            sans=sans,
            secret_prefix=config.secret_prefix,
            port=config.port,
        )

    def issue_internal_client(self, host: str, name: str, ca_host: str) -> IssueResult:
        config = self.configs.internal_client(host, name)
        if not config.enable:
            raise ToolError(f"internal HTTPS client {name} on host {host} is not enabled")
        sans = unique_strings([config.common_name, *config.sans])
        material = self.issuer.issue(ca_host, config.common_name, sans)
        self.store.write(host, config.secret_prefix, material, client=True)
        return IssueResult(
            kind="internal-client",
            host=host,
            name=name,
            common_name=config.common_name,
            sans=sans,
            secret_prefix=config.secret_prefix,
        )

    def issue_observability_endpoint(self, host: str, name: str, ca_host: str) -> IssueResult:
        config = self.configs.observability_endpoint(host, name)
        if not config.enable:
            raise ToolError(f"observability endpoint {name} on host {host} is not enabled")
        identity = self.configs.host_identity(host)
        fallback = [
            identity.dns_name,
            identity.networking_name,
            identity.avahi_name,
            f"{identity.avahi_name}.local",
        ]
        sans = unique_strings(config.sans or fallback)
        common_name = f"prometheus-{name}.{identity.dns_name}"
        material = self.issuer.issue(ca_host, common_name, sans)
        self.store.write(host, config.secret_prefix, material, client=False)
        return IssueResult(
            kind="observability-endpoint",
            host=host,
            name=name,
            common_name=common_name,
            sans=sans,
            secret_prefix=config.secret_prefix,
            port=config.port,
        )

    def issue_observability_client(self, host: str, name: str, ca_host: str) -> IssueResult:
        config = self.configs.observability_client(host, name)
        if not config.enable:
            raise ToolError(f"observability client {name} on host {host} is not enabled")
        sans = unique_strings(config.sans)
        material = self.issuer.issue(ca_host, config.common_name, sans)
        self.store.write(host, config.secret_prefix, material, client=True)
        return IssueResult(
            kind="observability-client",
            host=host,
            name=name,
            common_name=config.common_name,
            sans=sans,
            secret_prefix=config.secret_prefix,
        )
