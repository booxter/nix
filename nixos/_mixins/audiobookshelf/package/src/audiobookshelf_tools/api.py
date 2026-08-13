from __future__ import annotations

from collections.abc import Mapping
from typing import Protocol

import httpx

from .models import CurrentLibraries, CurrentSettings


class AudiobookshelfError(RuntimeError):
    pass


class AuthenticationRejected(AudiobookshelfError):
    pass


class ApiNotReady(AudiobookshelfError):
    def __init__(self, status_code: int | None) -> None:
        self.status_code = status_code
        status = str(status_code) if status_code is not None else "unreachable"
        super().__init__(f"Audiobookshelf API is not ready: {status}")


class InvalidResponse(AudiobookshelfError):
    pass


class UpdateFailed(AudiobookshelfError):
    def __init__(self, setting: str, status_code: int | None) -> None:
        self.status_code = status_code
        status = str(status_code) if status_code is not None else "unreachable"
        super().__init__(f"failed to update Audiobookshelf {setting}; HTTP status: {status}")


class AudiobookshelfApi(Protocol):
    def auth_settings(self) -> CurrentSettings: ...

    def settings(self) -> CurrentSettings: ...

    def libraries(self) -> CurrentLibraries: ...

    def update_auth_settings(self, settings: Mapping[str, object]) -> None: ...

    def update_settings(self, settings: Mapping[str, object]) -> None: ...

    def create_library(self, settings: Mapping[str, object]) -> None: ...

    def update_library(self, library_id: str, settings: Mapping[str, object]) -> None: ...


class HttpAudiobookshelfApi:
    def __init__(self, client: httpx.Client) -> None:
        self.client = client

    def _request_json(self, method: str, path: str, setting: str) -> object:
        try:
            response = self.client.request(method, path)
        except httpx.RequestError as error:
            raise ApiNotReady(None) from error
        if response.status_code in (401, 403):
            raise AuthenticationRejected("Audiobookshelf API token was rejected")
        if response.status_code != 200:
            raise ApiNotReady(response.status_code)
        try:
            return response.json()
        except ValueError as error:
            raise InvalidResponse(f"Audiobookshelf returned invalid {setting}") from error

    def auth_settings(self) -> CurrentSettings:
        try:
            return CurrentSettings.model_validate(
                self._request_json("GET", "/api/auth-settings", "auth settings")
            )
        except ValueError as error:
            raise InvalidResponse("Audiobookshelf returned invalid auth settings") from error

    def settings(self) -> CurrentSettings:
        try:
            response = self._request_json("POST", "/api/authorize", "settings")
            if not isinstance(response, dict):
                raise ValueError
            return CurrentSettings.model_validate(response["serverSettings"])
        except (KeyError, ValueError) as error:
            raise InvalidResponse("Audiobookshelf returned invalid settings") from error

    def libraries(self) -> CurrentLibraries:
        try:
            return CurrentLibraries.model_validate(
                self._request_json("GET", "/api/libraries", "libraries")
            )
        except ValueError as error:
            raise InvalidResponse("Audiobookshelf returned invalid libraries") from error

    def _write(self, method: str, path: str, setting: str, settings: Mapping[str, object]) -> None:
        try:
            response = self.client.request(method, path, json=settings)
        except httpx.RequestError as error:
            raise UpdateFailed(setting, None) from error
        if not response.is_success:
            raise UpdateFailed(setting, response.status_code)

    def update_auth_settings(self, settings: Mapping[str, object]) -> None:
        self._write("PATCH", "/api/auth-settings", "OIDC settings", settings)

    def update_settings(self, settings: Mapping[str, object]) -> None:
        self._write("PATCH", "/api/settings", "backup settings", settings)

    def create_library(self, settings: Mapping[str, object]) -> None:
        self._write("POST", "/api/libraries", "library", settings)

    def update_library(self, library_id: str, settings: Mapping[str, object]) -> None:
        self._write("PATCH", f"/api/libraries/{library_id}", "library", settings)
