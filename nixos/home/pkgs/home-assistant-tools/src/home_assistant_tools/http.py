from __future__ import annotations

from dataclasses import dataclass
from collections.abc import Mapping
from typing import Protocol, TypeVar

import httpx
from pydantic import BaseModel, ValidationError

from .errors import HomeAssistantError, HomeAssistantUnavailable
from .models import (
    AccessToken,
    AuthorizationCode,
    LoginFlow,
    OnboardingStatus,
    OnboardingStepName,
    OwnerAuthorizationCode,
)

ResponseModel = TypeVar("ResponseModel", bound=BaseModel)


class HomeAssistantApi(Protocol):
    async def onboarding_status(self) -> OnboardingStatus: ...

    async def create_owner(
        self,
        *,
        client_id: str,
        language: str,
        name: str,
        username: str,
        password: str,
    ) -> str: ...

    async def begin_login(self, client_id: str) -> str: ...

    async def complete_login(
        self,
        flow_id: str,
        *,
        client_id: str,
        username: str,
        password: str,
    ) -> str: ...

    async def access_token(self, client_id: str, authorization_code: str) -> str: ...

    async def complete_onboarding(
        self,
        step: OnboardingStepName,
        access_token: str,
        payload: dict[str, str],
    ) -> None: ...


@dataclass
class HttpxHomeAssistantApi:
    base_url: str
    timeout: float = 30
    http_client: httpx.AsyncClient | None = None

    async def __aenter__(self) -> HttpxHomeAssistantApi:
        if self.http_client is None:
            self.http_client = httpx.AsyncClient(base_url=self.base_url, timeout=self.timeout)
        return self

    async def __aexit__(self, *_args: object) -> None:
        if self.http_client is not None:
            await self.http_client.aclose()

    @property
    def client(self) -> httpx.AsyncClient:
        if self.http_client is None:
            raise HomeAssistantError("HTTP client is not open")
        return self.http_client

    async def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: object | None = None,
        form: Mapping[str, str] | None = None,
        headers: Mapping[str, str] | None = None,
        allow_not_found: bool = False,
    ) -> httpx.Response:
        try:
            response = await self.client.request(
                method,
                path,
                json=json_body,
                data=form,
                headers=headers,
            )
            if not (allow_not_found and response.status_code == 404):
                response.raise_for_status()
        except httpx.HTTPError as error:
            raise HomeAssistantUnavailable(f"Home Assistant request failed: {error}") from error
        return response

    @staticmethod
    def _model(response: httpx.Response, model: type[ResponseModel]) -> ResponseModel:
        try:
            return model.model_validate_json(response.content)
        except ValidationError as error:
            raise HomeAssistantError(f"invalid Home Assistant response: {error}") from error

    async def onboarding_status(self) -> OnboardingStatus:
        response = await self._request("GET", "/api/onboarding", allow_not_found=True)
        if response.status_code == 404:
            return OnboardingStatus.completed()
        return self._model(response, OnboardingStatus)

    async def create_owner(
        self,
        *,
        client_id: str,
        language: str,
        name: str,
        username: str,
        password: str,
    ) -> str:
        response = await self._request(
            "POST",
            "/api/onboarding/users",
            json_body={
                "client_id": client_id,
                "language": language,
                "name": name,
                "username": username,
                "password": password,
            },
        )
        return self._model(response, OwnerAuthorizationCode).auth_code

    async def begin_login(self, client_id: str) -> str:
        response = await self._request(
            "POST",
            "/auth/login_flow",
            json_body={
                "client_id": client_id,
                "handler": ["homeassistant", None],
                "redirect_uri": client_id,
            },
        )
        return self._model(response, LoginFlow).flow_id

    async def complete_login(
        self,
        flow_id: str,
        *,
        client_id: str,
        username: str,
        password: str,
    ) -> str:
        response = await self._request(
            "POST",
            f"/auth/login_flow/{flow_id}",
            json_body={
                "client_id": client_id,
                "username": username,
                "password": password,
            },
        )
        return self._model(response, AuthorizationCode).result

    async def access_token(self, client_id: str, authorization_code: str) -> str:
        response = await self._request(
            "POST",
            "/auth/token",
            form={
                "client_id": client_id,
                "grant_type": "authorization_code",
                "code": authorization_code,
            },
        )
        return self._model(response, AccessToken).access_token

    async def complete_onboarding(
        self,
        step: OnboardingStepName,
        access_token: str,
        payload: dict[str, str],
    ) -> None:
        await self._request(
            "POST",
            f"/api/onboarding/{step}",
            headers={"Authorization": f"Bearer {access_token}"},
            json_body=payload,
        )
