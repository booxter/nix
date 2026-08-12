from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from .errors import HomeAssistantUnavailable
from .http import HomeAssistantApi
from .models import AuthenticationConfig

AsyncSleep = Callable[[float], Awaitable[None]]
Clock = Callable[[], float]


@dataclass(frozen=True)
class LocalAuthenticator:
    api: HomeAssistantApi
    sleep: AsyncSleep = asyncio.sleep
    clock: Clock = time.monotonic

    async def login(
        self,
        config: AuthenticationConfig,
        password: str,
        *,
        retry_timeout: float | None = None,
        retry_interval: float = 2,
    ) -> str:
        deadline = self.clock() + retry_timeout if retry_timeout is not None else None
        while True:
            try:
                flow_id = await self.api.begin_login(config.client_id)
                break
            except HomeAssistantUnavailable:
                if deadline is None or self.clock() >= deadline:
                    raise
                await self.sleep(retry_interval)
        authorization_code = await self.api.complete_login(
            flow_id,
            client_id=config.client_id,
            username=config.owner_username,
            password=password,
        )
        return await self.api.access_token(config.client_id, authorization_code)


def read_password(config: AuthenticationConfig) -> str:
    return config.password_file.read_text(encoding="utf-8").rstrip("\n")
