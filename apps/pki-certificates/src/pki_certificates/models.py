from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, RootModel

ClientCategory = Literal["internal", "observability"]


class HostFacts(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    system: str
    configuration: Literal["nixosConfigurations", "darwinConfigurations"]
    runtime_host: str = Field(alias="runtimeHost")
    secret_domain: str = Field(alias="secretDomain")
    ca_url: str | None = Field(alias="caUrl")


class FleetHosts(RootModel[dict[str, HostFacts]]):
    model_config = ConfigDict(frozen=True, strict=True)


class InternalServiceConfig(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    enable: bool = False
    port: int
    secret_prefix: str = Field(alias="secretPrefix")
    server_name: str = Field(alias="serverName")
    server_aliases: list[str] = Field(default_factory=list, alias="serverAliases")
    sans: list[str] = Field(default_factory=list)


class CertificateClientConfig(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    enable: bool = False
    category: ClientCategory
    common_name: str = Field(alias="commonName")
    sans: list[str] = Field(default_factory=list)
    secret_prefix: str = Field(alias="secretPrefix")


class ObservabilityEndpointConfig(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    enable: bool = False
    port: int
    sans: list[str] = Field(default_factory=list)
    secret_prefix: str = Field(alias="secretPrefix")


class HostIdentity(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    dns_name: str
    networking_name: str
    avahi_name: str


class HostCertificateConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    identity: HostIdentity
    internal_services: dict[str, InternalServiceConfig]
    clients: dict[str, CertificateClientConfig]
    proxmox_api: InternalServiceConfig | None
    observability_endpoints: dict[str, ObservabilityEndpointConfig]
    node_exporter: ObservabilityEndpointConfig | None


class CertificateRequest(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    common_name: str
    sans: tuple[str, ...]
    ca_url: str


class CertificateMaterial(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    certificate_pem: str
    private_key_pem: str


class IssueResult(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    kind: Literal[
        "internal-service", "internal-client", "observability-endpoint", "observability-client"
    ]
    host: str
    name: str
    common_name: str
    sans: tuple[str, ...]
    secret_prefix: str
    port: int | None = None


class UnifiDefaults(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    common_name: str = Field(alias="commonName")
    sans: list[str]
    gateway_ip: str = Field(alias="gatewayIp")


class UnifiResult(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    kind: Literal["unifi"] = "unifi"
    ca_host: str
    common_name: str
    sans: tuple[str, ...]
    cert_file: str
    key_file: str
    pem_file: str
