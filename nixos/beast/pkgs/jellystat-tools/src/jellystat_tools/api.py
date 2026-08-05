from __future__ import annotations

from typing import TypeVar

import httpx
from pydantic import BaseModel

from .models import (
    ConfigurationState,
    EmptyRequest,
    JellyfinConfiguration,
    LibraryMetadata,
    LoginRequirement,
    TokenResponse,
    UserCredentials,
)

Model = TypeVar("Model", bound=BaseModel)


class JellystatApiError(RuntimeError):
    pass


class JellystatApi:
    def __init__(self, client: httpx.Client) -> None:
        self.client = client

    def _request(
        self,
        method: str,
        path: str,
        *,
        token: str | None = None,
        payload: BaseModel | None = None,
    ) -> httpx.Response:
        headers = {"Authorization": f"Bearer {token}"} if token is not None else None
        body = payload.model_dump(by_alias=True) if payload is not None else None
        try:
            response = self.client.request(method, path, headers=headers, json=body)
            response.raise_for_status()
            return response
        except httpx.HTTPError as error:
            raise JellystatApiError(f"Jellystat API request failed: {method} {path}") from error

    @staticmethod
    def _model(response: httpx.Response, model: type[Model], description: str) -> Model:
        try:
            return model.model_validate(response.json())
        except ValueError as error:
            raise JellystatApiError(f"Jellystat returned invalid {description}") from error

    def configuration_state(self) -> int:
        response = self._request("GET", "/auth/isConfigured")
        return self._model(response, ConfigurationState, "configuration state").state

    def create_user(self, credentials: UserCredentials) -> str | None:
        response = self._request("POST", "/auth/createuser", payload=credentials)
        return self._model(response, TokenResponse, "user response").token

    def configure(self, configuration: JellyfinConfiguration) -> None:
        self._request("POST", "/auth/configSetup", payload=configuration)

    def login(self) -> str | None:
        response = self._request("POST", "/auth/login", payload=EmptyRequest())
        return self._model(response, TokenResponse, "login response").token

    def set_configuration(self, token: str, configuration: JellyfinConfiguration) -> None:
        self._request("POST", "/api/setconfig", token=token, payload=configuration)

    def disable_login_requirement(self, token: str) -> None:
        self._request(
            "POST",
            "/api/setRequireLogin",
            token=token,
            payload=LoginRequirement(REQUIRE_LOGIN=False),
        )

    def library_count(self, token: str) -> int:
        response = self._request("GET", "/stats/getLibraryMetadata", token=token)
        return len(self._model(response, LibraryMetadata, "library metadata").root)

    def begin_sync(self, token: str) -> None:
        self._request("GET", "/sync/beginSync", token=token)

    def begin_backup(self, token: str) -> None:
        self._request("GET", "/backup/beginBackup", token=token)
