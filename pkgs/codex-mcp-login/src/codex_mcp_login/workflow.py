from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import TextIO

from .app_server import ProbeError, StatusProbe
from .login import LoginError, LoginRunner
from .models import ServerStartup, StartupStatus


@dataclass
class LoginWorkflow:
    probe: StatusProbe
    login: LoginRunner
    output: TextIO

    def run(self, server_names: Sequence[str]) -> int:
        servers = tuple(dict.fromkeys(server_names))
        self.note(f"Checking {len(servers)} MCP server(s)...")
        try:
            initial = self.probe.probe(servers)
        except ProbeError as error:
            self.note(f"error: {error}")
            return 1

        failures = False
        reauthentication: list[str] = []
        for status in initial:
            if status.status is StartupStatus.READY:
                self.note(f"{status.name}: ready")
            elif status.requires_reauthentication:
                self.note(f"{status.name}: reauthentication required")
                reauthentication.append(status.name)
            else:
                failures = True
                self.note(self._failure_message(status))

        repaired: list[str] = []
        for server_name in reauthentication:
            self.note(f"{server_name}: opening OAuth login")
            try:
                returncode = self.login.login(server_name)
            except LoginError as error:
                failures = True
                self.note(f"{server_name}: {error}")
                continue
            if returncode != 0:
                failures = True
                self.note(f"{server_name}: login failed with exit code {returncode}")
                continue
            repaired.append(server_name)

        if repaired:
            self.note(f"Verifying {len(repaired)} repaired MCP server(s)...")
            try:
                verified = self.probe.probe(repaired)
            except ProbeError as error:
                self.note(f"error: verification failed: {error}")
                return 1
            for status in verified:
                if status.status is StartupStatus.READY:
                    self.note(f"{status.name}: ready")
                else:
                    failures = True
                    self.note(self._failure_message(status, prefix="verification failed"))

        return 1 if failures else 0

    def note(self, message: str) -> None:
        print(message, file=self.output, flush=True)

    @staticmethod
    def _failure_message(status: ServerStartup, *, prefix: str = "startup failed") -> str:
        detail = status.error or status.failure_reason or status.status.value
        return f"{status.name}: {prefix}: {detail}"
