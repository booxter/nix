from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, RootModel, StrictInt, field_validator


class ConfigurationState(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    state: StrictInt


class UserCredentials(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    username: str = Field(min_length=1)
    password: str = Field(min_length=1)


class TokenResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    token: str | None = None

    @field_validator("token", mode="before")
    @classmethod
    def empty_token_is_missing(cls, value: object) -> object:
        return None if value == "" else value


class EmptyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class JellyfinConfiguration(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    jellyfin_host: str = Field(alias="JF_HOST", min_length=1)
    jellyfin_api_key: str = Field(alias="JF_API_KEY", min_length=1)


class LoginRequirement(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    require_login: bool = Field(alias="REQUIRE_LOGIN")


class LibraryMetadata(RootModel[list[object]]):
    pass
