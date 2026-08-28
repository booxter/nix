from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import Protocol


class LoginError(RuntimeError):
    """Codex MCP login could not be executed."""


class LoginRunner(Protocol):
    def login(self, server_name: str) -> int:
        """Run an interactive OAuth login and return its exit status."""


@dataclass(frozen=True)
class SubprocessLoginRunner:
    command: tuple[str, ...] = ("codex",)

    def login(self, server_name: str) -> int:
        try:
            result = subprocess.run(
                [*self.command, "mcp", "login", server_name],
                check=False,
            )
        except OSError as error:
            raise LoginError(f"could not execute {self.command[0]}: {error}") from error
        return result.returncode
