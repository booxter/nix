from __future__ import annotations

import asyncio
import json
from urllib.parse import parse_qs

import httpx
import pytest

from home_assistant_tools.errors import HomeAssistantError, HomeAssistantUnavailable
from home_assistant_tools.http import HttpxHomeAssistantApi


class InMemoryHttpHomeAssistant:
    def __init__(self) -> None:
        self.steps = {
            "user": False,
            "core_config": False,
            "analytics": False,
            "integration": False,
        }
        self.integration: dict[str, str] | None = None

    def __call__(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.method == "GET" and path == "/api/onboarding":
            return self.response(
                [{"step": step, "done": done} for step, done in self.steps.items()]
            )
        if path == "/api/onboarding/users":
            payload = json.loads(request.content)
            self.steps["user"] = True
            return self.response({"auth_code": f"owner:{payload['client_id']}"})
        if path == "/auth/login_flow":
            return self.response({"flow_id": "flow"})
        if path == "/auth/login_flow/flow":
            return self.response({"result": "login:client"})
        if path == "/auth/token":
            form = parse_qs(request.content.decode())
            return self.response({"access_token": f"token:{form['client_id'][0]}"})
        if path.startswith("/api/onboarding/"):
            step = path.rsplit("/", maxsplit=1)[1]
            self.steps[step] = True
            if step == "integration":
                self.integration = json.loads(request.content)
            return self.response({})
        return httpx.Response(404)

    @staticmethod
    def response(payload: object) -> httpx.Response:
        return httpx.Response(200, json=payload)


def test_http_adapter_exposes_home_assistant_operations() -> None:
    service = InMemoryHttpHomeAssistant()
    client = httpx.AsyncClient(
        base_url="http://home",
        transport=httpx.MockTransport(service),
    )

    async def exercise() -> None:
        async with HttpxHomeAssistantApi("http://home", http_client=client) as api:
            status = await api.onboarding_status()
            assert not status.complete
            owner_code = await api.create_owner(
                client_id="client",
                language="en",
                name="Owner",
                username="owner",
                password="secret",
            )
            assert await api.access_token("client", owner_code) == "token:client"
            flow_id = await api.begin_login("client")
            login_code = await api.complete_login(
                flow_id,
                client_id="client",
                username="owner",
                password="secret",
            )
            assert await api.access_token("client", login_code) == "token:client"
            for step in ("core_config", "analytics", "integration"):
                await api.complete_onboarding(
                    step,
                    "token:client",
                    {"client_id": "client"} if step == "integration" else {},
                )

    asyncio.run(exercise())

    assert all(service.steps.values())
    assert service.integration == {"client_id": "client"}


def test_http_adapter_reports_transport_and_model_failures() -> None:
    async def exercise() -> None:
        unavailable = httpx.AsyncClient(
            base_url="http://home",
            transport=httpx.MockTransport(lambda _request: httpx.Response(503)),
        )
        async with HttpxHomeAssistantApi("http://home", http_client=unavailable) as api:
            with pytest.raises(HomeAssistantUnavailable):
                await api.onboarding_status()

        invalid = httpx.AsyncClient(
            base_url="http://home",
            transport=httpx.MockTransport(lambda _request: httpx.Response(200, json={})),
        )
        async with HttpxHomeAssistantApi("http://home", http_client=invalid) as api:
            with pytest.raises(HomeAssistantError, match="invalid Home Assistant response"):
                await api.onboarding_status()

    asyncio.run(exercise())
