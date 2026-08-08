from __future__ import annotations

import json
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Protocol, TypeVar, cast
from urllib.parse import urlsplit, urlunsplit

from pydantic import BaseModel, ValidationError
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from .backup import BackupSession
from .errors import HomeAssistantError
from .models import BackupInfo, CommandResponse, WebsocketMessage

ResponseModel = TypeVar("ResponseModel", bound=BaseModel)


def websocket_url(base_url: str) -> str:
    parsed = urlsplit(base_url)
    scheme = {"http": "ws", "https": "wss"}.get(parsed.scheme)
    if scheme is None:
        raise HomeAssistantError(f"unsupported Home Assistant URL scheme: {parsed.scheme}")
    return urlunsplit((scheme, parsed.netloc, "/api/websocket", "", ""))


class WebsocketConnection(Protocol):
    async def recv(self) -> str | bytes: ...

    async def send(self, message: str) -> None: ...


@dataclass
class WebsocketBackupSession:
    connection: WebsocketConnection
    _command_id: int = 0

    @staticmethod
    def _model(payload: str | bytes | object, model: type[ResponseModel]) -> ResponseModel:
        try:
            if isinstance(payload, (str, bytes)):
                return model.model_validate_json(payload)
            return model.model_validate(payload)
        except ValidationError as error:
            raise HomeAssistantError(
                f"invalid Home Assistant WebSocket response: {error}"
            ) from error

    async def authenticate(self, access_token: str) -> None:
        greeting = self._model(await self.connection.recv(), WebsocketMessage)
        if greeting.type != "auth_required":
            raise HomeAssistantError(f"unexpected authentication greeting: {greeting.type}")
        await self.connection.send(json.dumps({"type": "auth", "access_token": access_token}))
        result = self._model(await self.connection.recv(), WebsocketMessage)
        if result.type != "auth_ok":
            raise HomeAssistantError(f"Home Assistant authentication failed: {result.type}")

    async def _command(self, message: dict[str, object]) -> object | None:
        self._command_id += 1
        command_id = self._command_id
        await self.connection.send(json.dumps({"id": command_id, **message}))
        response = self._model(await self.connection.recv(), CommandResponse)
        if response.id != command_id:
            raise HomeAssistantError(f"unexpected WebSocket response id: {response.id}")
        if not response.success:
            raise HomeAssistantError(f"Home Assistant command failed: {response.error}")
        return response.result

    async def info(self) -> BackupInfo:
        result = await self._command({"type": "backup/info"})
        return self._model(result, BackupInfo)

    async def generate(self) -> None:
        await self._command(
            {
                "type": "backup/generate",
                "agent_ids": ["backup.local"],
                "include_database": True,
                "include_homeassistant": True,
                "name": "Nix scheduled backup",
            }
        )

    async def delete(self, backup_id: str) -> None:
        await self._command({"type": "backup/delete", "backup_id": backup_id})


@dataclass(frozen=True)
class WebsocketBackupSessionFactory:
    base_url: str

    def __call__(self, access_token: str) -> AbstractAsyncContextManager[BackupSession]:
        return cast(AbstractAsyncContextManager[BackupSession], self._connect(access_token))

    @asynccontextmanager
    async def _connect(self, access_token: str) -> AsyncIterator[WebsocketBackupSession]:
        try:
            async with connect(websocket_url(self.base_url), open_timeout=30) as connection:
                session = WebsocketBackupSession(connection)
                await session.authenticate(access_token)
                yield session
        except (OSError, WebSocketException) as error:
            raise HomeAssistantError(f"Home Assistant WebSocket failed: {error}") from error
