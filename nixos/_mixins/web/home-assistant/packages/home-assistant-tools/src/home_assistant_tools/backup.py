from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from typing import Protocol

from .auth import LocalAuthenticator, read_password
from .errors import HomeAssistantError
from .models import BackupConfig, BackupInfo


class BackupSession(Protocol):
    async def info(self) -> BackupInfo: ...

    async def generate(self) -> None: ...

    async def delete(self, backup_id: str) -> None: ...


class BackupSessionFactory(Protocol):
    def __call__(self, access_token: str) -> AbstractAsyncContextManager[BackupSession]: ...


AsyncSleep = Callable[[float], Awaitable[None]]
Clock = Callable[[], float]


@dataclass(frozen=True)
class BackupManager:
    authenticator: LocalAuthenticator
    session_factory: BackupSessionFactory
    sleep: AsyncSleep = asyncio.sleep
    clock: Clock = time.monotonic

    async def run(self, config: BackupConfig) -> None:
        password = read_password(config.authentication)
        access_token = await self.authenticator.login(
            config.authentication,
            password,
            retry_timeout=config.login_timeout,
            retry_interval=config.poll_interval,
        )
        async with self.session_factory(access_token) as session:
            before = await session.info()
            previous_ids = {backup.backup_id for backup in before.backups}
            await session.generate()

            deadline = self.clock() + config.backup_timeout
            while True:
                await self.sleep(config.poll_interval)
                info = await session.info()
                created = [
                    backup
                    for backup in info.backups
                    if backup.backup_id not in previous_ids
                    and "backup.local" in backup.agents
                    and backup.database_included
                    and backup.homeassistant_included
                ]
                if created:
                    break
                if info.state == "idle":
                    raise HomeAssistantError(
                        "Home Assistant backup stopped without a local archive: "
                        f"{info.last_action_event}"
                    )
                if self.clock() >= deadline:
                    raise TimeoutError("Home Assistant native backup timed out")

            local_backups = sorted(
                (backup for backup in info.backups if "backup.local" in backup.agents),
                key=lambda backup: backup.date,
                reverse=True,
            )
            for backup in local_backups[config.keep_backups :]:
                await session.delete(backup.backup_id)
