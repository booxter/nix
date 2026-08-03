from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from .errors import ToolError
from .model import KeyPath
from .secrets import SecretService


@dataclass(frozen=True)
class UpsInventory:
    clients_by_server: dict[str, tuple[str, ...]]

    @classmethod
    def load(cls, path: Path) -> UpsInventory:
        try:
            value: object = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ToolError(f"Invalid UPS client inventory: {path}") from error
        if not isinstance(value, dict) or not all(
            isinstance(server, str)
            and isinstance(clients, list)
            and all(isinstance(client, str) for client in clients)
            for server, clients in value.items()
        ):
            raise ToolError(f"Invalid UPS client inventory: {path}")
        typed = cast(dict[str, list[str]], value)
        return cls({server: tuple(clients) for server, clients in typed.items()})

    @property
    def servers(self) -> tuple[str, ...]:
        return tuple(sorted(self.clients_by_server))

    def clients(self, server: str) -> tuple[str, ...]:
        return self.clients_by_server.get(server, ())


@dataclass
class UpsService:
    secrets: SecretService
    inventory: UpsInventory

    def sync_server(
        self, server: str, clients: tuple[str, ...] | None = None
    ) -> tuple[str, ...]:
        selected = self.inventory.clients(server) if clients is None else clients
        for client in selected:
            self.secrets.copy(
                server,
                client,
                KeyPath.parse("nut/users/upsslave/password"),
                KeyPath.from_segments("nut", "monitors", server, "password"),
            )
        return selected
