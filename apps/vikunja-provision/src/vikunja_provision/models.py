from __future__ import annotations

from typing import Annotated, Self

from pydantic import (
    AnyHttpUrl,
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    PositiveInt,
    RootModel,
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
    title: str = Field(min_length=1)
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


class SopsTarget(DeclarationModel):
    realm: str = Field(pattern=r"^[a-z][a-z0-9-]*$")
    key: str = Field(min_length=1)


class Declaration(DeclarationModel):
    server: AnyHttpUrl
    bot: BotSpec
    projects: list[ProjectSpec]
    token: TokenSpec
    seats: dict[Annotated[str, Field(pattern=r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$")], SopsTarget] = Field(
        default_factory=dict
    )

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
        if len({project.title for project in self.projects}) != len(self.projects):
            raise ValueError("project titles must be unique")

        return self

    @property
    def server_url(self) -> str:
        return str(self.server).rstrip("/")


class Declarations(RootModel[dict[str, dict[str, Declaration]]]):
    def select(self, host: str, bot: str) -> Declaration:
        if host not in self.root:
            raise ProvisionError(f"No Vikunja bot declarations for host {host}")

        if bot not in self.root[host]:
            raise ProvisionError(f"No Vikunja bot declaration {host}/{bot}")

        return self.root[host][bot]


class Project(BaseModel):
    id: PositiveInt
    title: str


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
    previous_token_id: PositiveInt | None = None


class Report(BaseModel):
    changes: list[str]
