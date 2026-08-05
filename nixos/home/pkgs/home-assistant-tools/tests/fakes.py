from __future__ import annotations

from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from home_assistant_tools.backup import BackupSession
from home_assistant_tools.errors import HomeAssistantUnavailable
from home_assistant_tools.models import (
    Backup,
    BackupInfo,
    OnboardingStatus,
    OnboardingStepName,
)


@dataclass
class InMemoryHomeAssistant:
    steps: dict[str, bool] = field(
        default_factory=lambda: {
            "user": False,
            "core_config": False,
            "analytics": False,
            "integration": False,
        }
    )
    owner: tuple[str, str, str, str] | None = None
    integration: dict[str, str] | None = None
    status_failures: int = 0
    login_failures: int = 0

    async def onboarding_status(self) -> OnboardingStatus:
        if self.status_failures:
            self.status_failures -= 1
            raise HomeAssistantUnavailable("starting")
        return OnboardingStatus.model_validate(
            [{"step": step, "done": done} for step, done in self.steps.items()]
        )

    async def create_owner(
        self,
        *,
        client_id: str,
        language: str,
        name: str,
        username: str,
        password: str,
    ) -> str:
        if self.steps["user"]:
            raise AssertionError("an existing owner must not be recreated")
        self.owner = (name, username, password, language)
        self.steps["user"] = True
        return f"owner:{client_id}"

    async def begin_login(self, client_id: str) -> str:
        if self.login_failures:
            self.login_failures -= 1
            raise HomeAssistantUnavailable("starting")
        if not self.steps["user"]:
            raise AssertionError("cannot log in before the owner exists")
        return f"flow:{client_id}"

    async def complete_login(
        self,
        flow_id: str,
        *,
        client_id: str,
        username: str,
        password: str,
    ) -> str:
        if self.owner is not None and self.owner[1:3] != (username, password):
            raise AssertionError("invalid owner credentials")
        if flow_id != f"flow:{client_id}":
            raise AssertionError("login flow does not belong to this client")
        return f"login:{client_id}"

    async def access_token(self, client_id: str, authorization_code: str) -> str:
        if authorization_code not in {f"owner:{client_id}", f"login:{client_id}"}:
            raise AssertionError("invalid authorization code")
        return f"token:{client_id}"

    async def complete_onboarding(
        self,
        step: OnboardingStepName,
        access_token: str,
        payload: dict[str, str],
    ) -> None:
        if access_token != "token:client":
            raise AssertionError("invalid access token")
        self.steps[step] = True
        if step == "integration":
            self.integration = payload


@dataclass
class InMemoryBackupSession:
    backups: list[Backup]
    generation: str = "success"
    state: str = "idle"
    last_action_event: object | None = None

    async def info(self) -> BackupInfo:
        return BackupInfo(
            backups=list(self.backups),
            state=self.state,
            last_action_event=self.last_action_event,
        )

    async def generate(self) -> None:
        if self.generation == "success":
            self.backups.append(backup("generated", 1))
            self.state = "idle"
        elif self.generation == "running":
            self.state = "creating"
        else:
            self.state = "idle"
            self.last_action_event = {"event": "failed"}

    async def delete(self, backup_id: str) -> None:
        self.backups = [backup for backup in self.backups if backup.backup_id != backup_id]


@dataclass(frozen=True)
class SessionContext(AbstractAsyncContextManager[BackupSession]):
    session: InMemoryBackupSession

    async def __aenter__(self) -> BackupSession:
        return self.session

    async def __aexit__(self, *_args: object) -> None:
        return None


@dataclass(frozen=True)
class InMemoryBackupFactory:
    session: InMemoryBackupSession

    def __call__(self, access_token: str) -> AbstractAsyncContextManager[BackupSession]:
        if access_token != "token:client":
            raise AssertionError("backup session received an invalid access token")
        return SessionContext(self.session)


@dataclass
class FakeTime:
    value: float = 0

    def now(self) -> float:
        return self.value

    async def sleep(self, seconds: float) -> None:
        self.value += seconds


def backup(backup_id: str, days_ago: int, *, local: bool = True) -> Backup:
    return Backup(
        backup_id=backup_id,
        agents=["backup.local"] if local else ["backup.remote"],
        database_included=True,
        homeassistant_included=True,
        date=(datetime.now(UTC) - timedelta(days=days_ago)).isoformat(),
    )
