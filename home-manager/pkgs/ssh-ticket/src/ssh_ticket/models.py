from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, model_validator

from .durations import parse_duration


class Target(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

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
    def validate_ticket_lifetimes(self) -> "Target":
        default_ttl = parse_duration(self.default_ttl)
        max_ttl = parse_duration(self.max_ttl)
        if default_ttl > max_ttl:
            raise ValueError("defaultTtl must not exceed maxTtl")
        return self


TARGETS = TypeAdapter(list[Target])
