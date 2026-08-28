from __future__ import annotations

import asyncio
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from pydantic import ValidationError

from .models import (
    RpcEnvelope,
    ServerStartup,
    StartupNotification,
    StartupStatus,
    ThreadStartResponse,
)


class ProbeError(RuntimeError):
    """Codex app-server could not determine MCP startup status."""


class StatusProbe(Protocol):
    def probe(self, server_names: Sequence[str]) -> tuple[ServerStartup, ...]:
        """Start the configured servers and return their terminal status."""


@dataclass(frozen=True)
class SubprocessStatusProbe:
    command: tuple[str, ...] = ("codex",)
    timeout_seconds: float = 90.0
    shutdown_timeout_seconds: float = 5.0
    environment: Mapping[str, str] | None = None
    working_directory: Path = field(default_factory=Path.cwd)

    def probe(self, server_names: Sequence[str]) -> tuple[ServerStartup, ...]:
        if not server_names:
            return ()
        try:
            return asyncio.run(self._probe(tuple(dict.fromkeys(server_names))))
        except OSError as error:
            raise ProbeError(f"could not execute {self.command[0]}: {error}") from error

    async def _probe(self, server_names: tuple[str, ...]) -> tuple[ServerStartup, ...]:
        process = await asyncio.create_subprocess_exec(
            *self.command,
            "app-server",
            "--stdio",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            env=self.environment,
        )
        if process.stdin is None or process.stdout is None:
            process.kill()
            await process.wait()
            raise ProbeError("codex app-server did not expose stdio pipes")

        requests = (
            {
                "method": "initialize",
                "id": 1,
                "params": {
                    "clientInfo": {
                        "name": "codex_mcp_login",
                        "title": "Codex MCP login",
                        "version": "0.1.0",
                    }
                },
            },
            {"method": "initialized", "params": {}},
            {
                "method": "thread/start",
                "id": 2,
                "params": {"cwd": str(self.working_directory), "ephemeral": True},
            },
        )
        payload = "".join(f"{json.dumps(request, separators=(',', ':'))}\n" for request in requests)
        process.stdin.write(payload.encode())
        await process.stdin.drain()

        try:
            statuses = await self._read_statuses(process, server_names)
        finally:
            await self._shutdown(process)
        return tuple(statuses[name] for name in server_names)

    async def _read_statuses(
        self,
        process: asyncio.subprocess.Process,
        server_names: tuple[str, ...],
    ) -> dict[str, ServerStartup]:
        assert process.stdout is not None
        pending = set(server_names)
        statuses: dict[str, ServerStartup] = {}
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.timeout_seconds

        while pending:
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise self._timeout_error(pending)
            try:
                line = await asyncio.wait_for(process.stdout.readline(), timeout=remaining)
            except TimeoutError as error:
                raise self._timeout_error(pending) from error
            if not line:
                returncode = await process.wait()
                missing = ", ".join(sorted(pending))
                raise ProbeError(
                    f"codex app-server exited with code {returncode} before reporting: {missing}"
                )

            try:
                envelope = RpcEnvelope.model_validate_json(line)
            except ValidationError as error:
                raise ProbeError(f"codex app-server emitted invalid JSON-RPC: {error}") from error

            if envelope.id == 2:
                response = ThreadStartResponse.model_validate_json(line)
                if response.error is not None:
                    raise ProbeError(
                        f"codex app-server could not start probe: {response.error.message}"
                    )
                continue
            if envelope.method != "mcpServer/startupStatus/updated":
                continue

            try:
                notification = StartupNotification.model_validate_json(line)
            except ValidationError as error:
                raise ProbeError(f"invalid MCP startup notification: {error}") from error
            parameters = notification.params
            if parameters.name not in pending or parameters.status == "starting":
                continue
            status = ServerStartup(
                name=parameters.name,
                status=StartupStatus(parameters.status),
                error=parameters.error,
                failure_reason=parameters.failure_reason,
            )
            statuses[status.name] = status
            pending.remove(status.name)
        return statuses

    async def _shutdown(self, process: asyncio.subprocess.Process) -> None:
        if process.stdin is not None:
            process.stdin.close()
            try:
                await process.stdin.wait_closed()
            except (BrokenPipeError, ConnectionResetError):
                pass
        try:
            await asyncio.wait_for(process.wait(), timeout=self.shutdown_timeout_seconds)
            return
        except TimeoutError:
            process.terminate()
        try:
            await asyncio.wait_for(process.wait(), timeout=self.shutdown_timeout_seconds)
        except TimeoutError:
            process.kill()
            await process.wait()

    @staticmethod
    def _timeout_error(pending: set[str]) -> ProbeError:
        return ProbeError(f"timed out waiting for MCP startup status: {', '.join(sorted(pending))}")
