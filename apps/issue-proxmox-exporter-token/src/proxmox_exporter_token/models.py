from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, RootModel


class HostFacts(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    system: str
    secret_domain: str = Field(alias="secretDomain")
    is_work: bool = Field(alias="isWork")


class FleetHosts(RootModel[dict[str, HostFacts]]):
    model_config = ConfigDict(frozen=True, strict=True)


class FlakeArchive(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    path: str


class ExporterConfig(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    enable: bool = False
    api_user: str = Field(alias="apiUser")
    api_token_name: str = Field(alias="apiTokenName")
    api_token_value_secret: str = Field(alias="apiTokenValueSecret")


class TokenPayload(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    value: str


class TokenResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    value: str | None = None
    data: TokenPayload | None = None

    def token_value(self) -> str:
        value = self.value or (self.data.value if self.data is not None else None)
        if not value:
            raise ValueError("pveum token response did not include a value")
        return value


class RemoteTokenRequest(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    user: str
    token_name: str
    role: str
    acl_path: str
    replace: bool
    comment: str


class PveUser(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    userid: str


class PveUserList(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    data: list[PveUser]


class IssueSummary(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    issuer_host: str
    user: str
    token_name: str
    role: str
    path: str
    updated_hosts: tuple[str, ...]
