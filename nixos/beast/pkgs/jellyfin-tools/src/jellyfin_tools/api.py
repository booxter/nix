from __future__ import annotations

from typing import Protocol, cast

from jellyfin_apiclient_python import JellyfinClient  # type: ignore[import-untyped]
from pydantic import ValidationError

from .models import BackupManifest, Session, Sessions


class NativeConfiguration(Protocol):
    def app(self, name: str, version: str, device_name: str, device_id: str) -> None: ...

    def auth(
        self,
        server: str,
        user_id: str,
        token: str | None = None,
        ssl: bool | None = None,
    ) -> None: ...

    def http(
        self,
        user_agent: str | None = None,
        max_retries: int = 3,
        timeout: int = 30,
    ) -> None: ...


class NativeApi(Protocol):
    def sessions(self) -> object: ...

    def create_backup(
        self,
        include_metadata: bool = False,
        include_subtitles: bool = False,
        include_trickplay: bool = False,
    ) -> object: ...


class NativeClient(Protocol):
    config: NativeConfiguration
    jellyfin: NativeApi


class JellyfinApiError(RuntimeError):
    pass


class JellyfinApi:
    def __init__(self, base_url: str, api_key: str) -> None:
        client = cast(NativeClient, JellyfinClient())
        client.config.app(
            "beast-jellyfin-tools",
            "0.1.0",
            "beast",
            "beast-jellyfin-tools",
        )
        client.config.auth(base_url, "", token=api_key, ssl=False)
        client.config.http(max_retries=0, timeout=10)
        self.api = client.jellyfin

    def sessions(self) -> tuple[Session, ...]:
        try:
            response = self.api.sessions()
        except Exception as error:
            raise JellyfinApiError("Unable to query Jellyfin sessions") from error
        try:
            return Sessions.model_validate(response).root
        except ValidationError as error:
            raise JellyfinApiError("Jellyfin returned invalid sessions") from error

    def create_backup(self) -> BackupManifest:
        try:
            response = self.api.create_backup(
                include_metadata=False,
                include_subtitles=False,
                include_trickplay=False,
            )
        except Exception as error:
            raise JellyfinApiError("Unable to create a Jellyfin backup") from error
        try:
            return BackupManifest.model_validate(response)
        except ValidationError as error:
            raise JellyfinApiError("Jellyfin returned an invalid backup manifest") from error
