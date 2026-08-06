from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, model_validator

from .durations import parse_duration


class Target(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, populate_by_name=True, strict=True)

    name: str = Field(min_length=1)
    enabled: bool = False
    kind: Literal["darwin", "nixos"] = "nixos"
    ssh_host: str = Field(default="", alias="sshHost")
    aliases: list[str] = Field(default_factory=list)
    allow_x11_forwarding: bool = Field(default=False, alias="allowX11Forwarding")
    principal: str = ""
    default_ttl: str = Field(default="30m", alias="defaultTtl")
    max_ttl: str = Field(default="2h", alias="maxTtl")
    ca_public_key_configured: bool = Field(default=False, alias="caPublicKeyConfigured")

    @model_validator(mode="after")
    def validate_ticket_lifetimes(self) -> Self:
        default_ttl = parse_duration(self.default_ttl)
        max_ttl = parse_duration(self.max_ttl)
        if default_ttl > max_ttl:
            raise ValueError("defaultTtl must not exceed maxTtl")
        return self


TARGETS: TypeAdapter[list[Target]] = TypeAdapter(list[Target])


class TicketStatus(Target):
    status: Literal["missing", "expired", "valid"]
    valid_before: int | None = Field(default=None, alias="validBefore")


class TicketMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, populate_by_name=True, strict=True)

    target: str = Field(min_length=1)
    ssh_host: str = Field(default="", alias="sshHost")
    principal: str = ""
    identity: str = ""
    valid_after: int = Field(default=0, alias="validAfter")
    valid_before: int = Field(default=0, alias="validBefore")
    issued_at: int = Field(default=0, alias="issuedAt")
    ttl: int = Field(default=0, ge=0)
    allow_x11_forwarding: bool = Field(default=False, alias="allowX11Forwarding")
    certificate_file: str = Field(default="", alias="certificateFile")
    identity_file: str = Field(default="", alias="identityFile")
    ca_agent: bool = Field(default=False, alias="caAgent")
    ca_key: str = Field(default="", alias="caKey")


@dataclass(frozen=True)
class TicketPaths:
    public: Path
    cert: Path
    metadata: Path
