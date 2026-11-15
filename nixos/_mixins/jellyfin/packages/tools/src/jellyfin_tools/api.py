from __future__ import annotations

from typing import Protocol, cast

from jellyfin_apiclient_python import JellyfinClient  # type: ignore[import-untyped]
from pydantic import BaseModel, ValidationError

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
    def get_plugins(self) -> object: ...

    def virtual_folders(self) -> object: ...

    def _get(self, handler: str) -> object: ...

    def _post(self, handler: str, json: object = None) -> object: ...

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
            "jellyfin-tools",
            "0.1.0",
            "nixos",
            "jellyfin-tools",
        )
        client.config.auth(base_url, "", token=api_key, ssl=False)
        client.config.http(max_retries=0, timeout=120)
        self.api = client.jellyfin

    def plugins(self) -> object:
        return self.api.get_plugins()

    def libraries(self) -> object:
        return self.api.virtual_folders()

    # The client has no named bindings for plugin configuration or scheduled
    # tasks. Use its transport so authentication and HTTP handling stay shared.
    def plugin_configuration(self, plugin_id: str) -> object:
        return self.api._get(f"Plugins/{plugin_id}/Configuration")

    def update_plugin_configuration(self, plugin_id: str, configuration: BaseModel) -> None:
        self.api._post(
            f"Plugins/{plugin_id}/Configuration",
            json=configuration.model_dump(mode="json", by_alias=True),
        )

    def tasks(self) -> object:
        return self.api._get("ScheduledTasks")

    def start_task(self, task_id: str) -> None:
        self.api._post(f"ScheduledTasks/Running/{task_id}")

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
