from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from datetime import UTC, datetime

import pytest

from home_assistant_tools.errors import HomeAssistantError
from home_assistant_tools.websocket import WebsocketBackupSession, websocket_url


@dataclass
class InMemoryWebsocket:
    responses: list[str] = field(default_factory=lambda: [json.dumps({"type": "auth_required"})])
    backups: list[dict[str, object]] = field(default_factory=list)

    async def recv(self) -> str:
        return self.responses.pop(0)

    async def send(self, message: str) -> None:
        request = json.loads(message)
        if request["type"] == "auth":
            self.responses.append(json.dumps({"type": "auth_ok"}))
            return
        if request["type"] == "backup/generate":
            self.backups.append(
                {
                    "backup_id": "generated",
                    "agents": ["backup.local"],
                    "database_included": True,
                    "homeassistant_included": True,
                    "date": datetime.now(UTC).isoformat(),
                }
            )
            result: object | None = None
        elif request["type"] == "backup/delete":
            self.backups = [
                backup for backup in self.backups if backup["backup_id"] != request["backup_id"]
            ]
            result = None
        else:
            result = {"backups": self.backups, "state": "idle"}
        self.responses.append(json.dumps({"id": request["id"], "success": True, "result": result}))


def test_websocket_url_preserves_authority_and_selects_secure_scheme() -> None:
    assert websocket_url("http://127.0.0.1:8123") == "ws://127.0.0.1:8123/api/websocket"
    assert websocket_url("https://home.example/path") == "wss://home.example/api/websocket"

    with pytest.raises(HomeAssistantError, match="unsupported"):
        websocket_url("file:///home-assistant")


def test_websocket_session_exposes_backup_behavior() -> None:
    connection = InMemoryWebsocket()
    session = WebsocketBackupSession(connection)

    async def exercise() -> None:
        await session.authenticate("token")
        assert (await session.info()).backups == []
        await session.generate()
        assert [backup.backup_id for backup in (await session.info()).backups] == ["generated"]
        await session.delete("generated")
        assert (await session.info()).backups == []

    asyncio.run(exercise())


def test_websocket_session_rejects_invalid_protocol_messages() -> None:
    connection = InMemoryWebsocket(responses=["not-json"])

    with pytest.raises(HomeAssistantError, match="invalid Home Assistant WebSocket response"):
        asyncio.run(WebsocketBackupSession(connection).authenticate("token"))
