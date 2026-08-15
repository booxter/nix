from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from .auth import LocalAuthenticator, read_password
from .errors import HomeAssistantUnavailable
from .http import HomeAssistantApi
from .models import BootstrapConfig, OnboardingStepName

AsyncSleep = Callable[[float], Awaitable[None]]


@dataclass(frozen=True)
class Bootstrapper:
    api: HomeAssistantApi
    authenticator: LocalAuthenticator
    sleep: AsyncSleep = asyncio.sleep

    async def run(self, config: BootstrapConfig) -> None:
        while True:
            try:
                status = await self.api.onboarding_status()
                break
            except HomeAssistantUnavailable:
                await self.sleep(2)

        if status.complete:
            return

        authentication = config.authentication
        password = read_password(authentication)
        if status.is_done("user"):
            access_token = await self.authenticator.login(authentication, password)
        else:
            authorization_code = await self.api.create_owner(
                client_id=authentication.client_id,
                language=config.owner_language,
                name=config.owner_display_name,
                username=authentication.owner_username,
                password=password,
            )
            access_token = await self.api.access_token(
                authentication.client_id,
                authorization_code,
            )

        steps: tuple[tuple[OnboardingStepName, dict[str, str]], ...] = (
            ("core_config", {}),
            ("analytics", {}),
            (
                "integration",
                {
                    "client_id": authentication.client_id,
                    "redirect_uri": authentication.client_id,
                },
            ),
        )
        for step, payload in steps:
            if not status.is_done(step):
                await self.api.complete_onboarding(step, access_token, payload)
