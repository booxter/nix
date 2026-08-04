from __future__ import annotations

import ipaddress
from dataclasses import dataclass
from typing import Self

from pydantic import (
    AliasChoices,
    BaseModel,
    ConfigDict,
    Field,
    RootModel,
    ValidationError,
    field_validator,
    model_validator,
)
from unifi_sync.dns import normalize_dns_name
from unifi_sync.errors import UnifiError


class SyncError(RuntimeError):
    pass


@dataclass(frozen=True)
class PeerDnsSpec:
    name: str
    public_key: str
    domain: str
    address: ipaddress.IPv4Address


class PeerDnsModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    name: str = Field(min_length=1)
    public_key: str = Field(
        min_length=1,
        validation_alias=AliasChoices("publicKey", "public_key"),
    )
    domain: str = Field(min_length=1)
    address: ipaddress.IPv4Address

    @field_validator("name", "public_key", mode="before")
    @classmethod
    def strip_nonempty(cls, value: object) -> object:
        return value.strip() if isinstance(value, str) else value

    @field_validator("domain", mode="before")
    @classmethod
    def normalize_domain(cls, value: object) -> object:
        if not isinstance(value, str):
            return value
        try:
            return normalize_dns_name(value)
        except UnifiError as error:
            raise ValueError(str(error)) from error

    def spec(self) -> PeerDnsSpec:
        return PeerDnsSpec(
            name=self.name,
            public_key=self.public_key,
            domain=self.domain,
            address=self.address,
        )


class PeerDnsInventory(RootModel[list[PeerDnsModel]]):
    model_config = ConfigDict(frozen=True, strict=True)

    @model_validator(mode="after")
    def validate_unique_fields(self) -> Self:
        for field_name, description in (
            ("name", "name"),
            ("public_key", "publicKey"),
            ("domain", "domain"),
        ):
            values = [getattr(peer, field_name) for peer in self.root]
            duplicate = next((value for value in values if values.count(value) > 1), None)
            if duplicate is not None:
                raise ValueError(f"duplicate peer DNS {description}: {duplicate}")
        return self

    def specs(self) -> list[PeerDnsSpec]:
        return [peer.spec() for peer in self.root]


def load_peer_dns_specs(raw_json: str) -> list[PeerDnsSpec]:
    if not raw_json:
        raise SyncError("missing peer DNS JSON")
    try:
        return PeerDnsInventory.model_validate_json(raw_json).specs()
    except ValidationError as error:
        raise SyncError(f"invalid peer DNS JSON: {error}") from error
