from __future__ import annotations

from collections.abc import Mapping
from typing import Protocol

import httpx

from .models import CurrentSettings


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

    def update_auth_settings(self, settings: Mapping[str, object]) -> None: ...

    def update_backup_settings(self, settings: Mapping[str, object]) -> None: ...


class HttpAudiobookshelfApi:
    def __init__(self, client: httpx.Client) -> None:
        self.client = client

    def auth_settings(self) -> CurrentSettings:
        try:
            response = self.client.get("/api/auth-settings")
        except httpx.RequestError as error:
            raise ApiNotReady(None) from error
        if response.status_code in (401, 403):
            raise AuthenticationRejected("Audiobookshelf API token was rejected")
        if response.status_code != 200:
            raise ApiNotReady(response.status_code)
        try:
            return CurrentSettings.model_validate(response.json())
        except ValueError as error:
            raise InvalidResponse("Audiobookshelf returned invalid auth settings") from error

    def _update(self, path: str, setting: str, settings: Mapping[str, object]) -> None:
        try:
            response = self.client.patch(path, json=settings)
        except httpx.RequestError as error:
            raise UpdateFailed(setting, None) from error
        if not response.is_success:
            raise UpdateFailed(setting, response.status_code)

    def update_auth_settings(self, settings: Mapping[str, object]) -> None:
        self._update("/api/auth-settings", "OIDC settings", settings)

    def update_backup_settings(self, settings: Mapping[str, object]) -> None:
        self._update("/api/settings", "backup settings", settings)
