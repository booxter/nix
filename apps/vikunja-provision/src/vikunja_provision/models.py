from __future__ import annotations

from typing import Self

from pydantic import (
    AnyHttpUrl,
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    PositiveInt,
    SecretStr,
    field_validator,
    model_validator,
)


class ProvisionError(Exception):
    """An actionable error safe to show without disclosing credentials."""


class DeclarationModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class BotSpec(DeclarationModel):
    username: str = Field(pattern=r"^bot-[a-zA-Z0-9_.-]+$")
    name: str


class ProjectSpec(DeclarationModel):
    id: PositiveInt
    permission: int = Field(ge=0, le=2)


class TokenSpec(DeclarationModel):
    title: str = Field(min_length=1)
    permissions: dict[str, list[str]]
    expires_at: AwareDatetime

    @field_validator("permissions")
    @classmethod
    def require_mcp_access(cls, value: dict[str, list[str]]) -> dict[str, list[str]]:
        if "access" not in value.get("mcp", []):
            raise ValueError("permissions must include mcp.access")

        return value


class Declaration(DeclarationModel):
    server: AnyHttpUrl
    bot: BotSpec
    projects: list[ProjectSpec]
    token: TokenSpec

    @field_validator("server")
    @classmethod
    def require_secure_server(cls, value: AnyHttpUrl) -> AnyHttpUrl:
        if value.username or value.password or value.query or value.fragment:
            raise ValueError("server must not contain credentials, a query, or a fragment")

        if value.scheme != "https" and value.host not in {"localhost", "127.0.0.1", "[::1]"}:
            raise ValueError("HTTP is allowed only on loopback; use HTTPS")

        return value

    @model_validator(mode="after")
    def require_unique_projects(self) -> Self:
        if len({project.id for project in self.projects}) != len(self.projects):
            raise ValueError("project IDs must be unique")

        return self

    @property
    def server_url(self) -> str:
        return str(self.server).rstrip("/")


class Bot(BaseModel):
    id: PositiveInt
    username: str
    name: str
    status: int


class Share(BaseModel):
    username: str
    permission: int


class Token(BaseModel):
    id: PositiveInt
    title: str
    owner_id: PositiveInt
    permissions: dict[str, list[str]]
    expires_at: AwareDatetime

    def matches(self, desired: TokenSpec) -> bool:
        permissions = {group: set(actions) for group, actions in self.permissions.items()}
        wanted = {group: set(actions) for group, actions in desired.permissions.items()}
        return (
            self.title == desired.title
            and permissions == wanted
            and self.expires_at == desired.expires_at
        )


class IssuedToken(Token):
    token: SecretStr = Field(min_length=4)


class Credentials(DeclarationModel):
    server: str
    bot_id: PositiveInt
    token_id: PositiveInt
    token: SecretStr = Field(min_length=4)


class Report(BaseModel):
    changes: list[str]
