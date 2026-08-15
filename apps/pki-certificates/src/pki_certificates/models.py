from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, RootModel

CertificateCategory = Literal[
    "internal_https_server",
    "internal_https_client",
    "observability_endpoint_server",
    "observability_client",
]


class FleetHost(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    system: str
    configuration: Literal["nixosConfigurations", "darwinConfigurations"]
    runtime_host: str = Field(alias="runtimeHost")
    realm: str


class FleetHosts(RootModel[dict[str, FleetHost]]):
    model_config = ConfigDict(frozen=True, strict=True)


class CertificateConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    category: CertificateCategory
    name: str
    common_name: str = Field(alias="commonName")
    sans: list[str]
    secret_prefix: str = Field(alias="secretPrefix")
    port: int | None = None


class RealmAuthorityConfig(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    host_name: str = Field(alias="hostName")
    realm: str
    url: str
    provisioner: str
    root_ca_certificate: str = Field(alias="rootCaCertificate")


class HostCertificateConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    realm: str
    realm_authority: RealmAuthorityConfig | None
    certificates: list[CertificateConfig]


class CertificateRequest(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    common_name: str
    sans: tuple[str, ...]
    ca_url: str
    provisioner: str


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


class UnifiResult(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    kind: Literal["unifi"] = "unifi"
    ca_host: str
    common_name: str
    sans: tuple[str, ...]
    cert_file: str
    key_file: str
    pem_file: str
