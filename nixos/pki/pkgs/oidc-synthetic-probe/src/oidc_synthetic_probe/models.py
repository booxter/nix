from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class APIModel(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)


class AuthState(APIModel):
    choose: list[str] | None = None
    continue_: list[str] | None = Field(default=None, alias="continue")
    success: Any | None = None

    def variant(self, name: str) -> Any | None:
        if name == "continue":
            return self.continue_
        return getattr(self, name, None)


class AuthResponse(APIModel):
    state: AuthState


class Discovery(APIModel):
    jwks_uri: str | None = None
    authorization_endpoint: str | None = None
    token_endpoint: str | None = None
    userinfo_endpoint: str | None = None


class JWKS(APIModel):
    keys: list[dict[str, Any]] = Field(min_length=1)


class TokenResponse(APIModel):
    access_token: str = Field(min_length=1)


class UserInfo(APIModel):
    sub: str = Field(min_length=1)


class ProbeState(APIModel):
    last_success: int = Field(default=0, ge=0)


class StateFile(APIModel):
    probes: dict[str, ProbeState] = Field(default_factory=dict)
