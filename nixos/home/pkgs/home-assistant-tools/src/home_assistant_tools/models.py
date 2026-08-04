from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, RootModel


class ApiModel(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)


class OnboardingStep(ApiModel):
    step: str
    done: bool


class OnboardingStatus(RootModel[list[OnboardingStep]]):
    def is_done(self, step: str) -> bool:
        return any(item.step == step and item.done for item in self.root)

    @property
    def complete(self) -> bool:
        return all(item.done for item in self.root)


class LoginFlow(ApiModel):
    flow_id: str


class AuthorizationCode(ApiModel):
    result: str


class OwnerAuthorizationCode(ApiModel):
    auth_code: str


class AccessToken(ApiModel):
    access_token: str


class Backup(ApiModel):
    backup_id: str
    agents: list[str]
    database_included: bool
    homeassistant_included: bool
    date: str


class BackupInfo(ApiModel):
    backups: list[Backup]
    state: str
    last_action_event: object | None = None


class WebsocketMessage(ApiModel):
    type: str


class CommandResponse(ApiModel):
    id: int
    success: bool
    result: object | None = None
    error: object | None = None


@dataclass(frozen=True)
class AuthenticationConfig:
    base_url: str
    client_id: str
    owner_username: str
    password_file: Path


@dataclass(frozen=True)
class BootstrapConfig:
    authentication: AuthenticationConfig
    owner_display_name: str
    owner_language: str


@dataclass(frozen=True)
class BackupConfig:
    authentication: AuthenticationConfig
    keep_backups: int = 7
    login_timeout: float = 300
    backup_timeout: float = 7200
    poll_interval: float = 2


OnboardingStepName = Literal["core_config", "analytics", "integration"]
