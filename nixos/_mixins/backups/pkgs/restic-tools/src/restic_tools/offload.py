from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from .clients import CommandRunner
from .models import OffloadConfig


class OffloadFailure(RuntimeError):
    def __init__(self, operation: str, exit_code: int) -> None:
        super().__init__(f"restic {operation} failed with exit code {exit_code}")
        self.exit_code = exit_code


class OffloadClient(Protocol):
    def destination_exists(self) -> bool: ...

    def initialize(self) -> None: ...

    def unlock(self) -> None: ...

    def copy(self) -> None: ...

    def forget(self) -> None: ...

    def prune(self) -> None: ...


@dataclass(frozen=True)
class ResticOffloadClient:
    config: OffloadConfig
    runner: CommandRunner
    environment: Mapping[str, str]

    def _destination_command(self, arguments: Sequence[str]) -> list[str]:
        return [
            "restic",
            "-r",
            self.config.destination_repository,
            "--password-file",
            str(self.config.destination_password_file),
            *arguments,
        ]

    def _checked(self, operation: str, arguments: Sequence[str]) -> None:
        result = self.runner.run(
            self._destination_command(arguments),
            self.environment,
            capture_output=False,
        )
        if result.returncode != 0:
            raise OffloadFailure(operation, result.returncode)

    def destination_exists(self) -> bool:
        result = self.runner.run(
            self._destination_command(("cat", "config")),
            self.environment,
        )
        return result.returncode == 0

    def initialize(self) -> None:
        self._checked(
            "init",
            (
                "init",
                "--from-repo",
                str(self.config.source_repository),
                "--from-password-file",
                str(self.config.source_password_file),
                "--copy-chunker-params",
            ),
        )

    def unlock(self) -> None:
        self.runner.run(
            self._destination_command(("unlock",)),
            self.environment,
            capture_output=False,
        )

    def copy(self) -> None:
        backend_options = (
            ("-o", f"{self.config.backend}.connections={self.config.backend_connections}")
            if self.config.backend != "local"
            else ()
        )
        self._checked(
            "copy",
            (
                *backend_options,
                "--pack-size",
                str(self.config.pack_size_mib),
                "copy",
                "--from-repo",
                str(self.config.source_repository),
                "--from-password-file",
                str(self.config.source_password_file),
                "--verbose",
            ),
        )

    def forget(self) -> None:
        self._checked("forget", ("forget", *self.config.prune_options))

    def prune(self) -> None:
        self._checked("prune", ("prune",))


def offload(client: OffloadClient) -> None:
    try:
        if not client.destination_exists():
            client.initialize()
        client.unlock()
        client.copy()
    except Exception:
        client.unlock()
        raise


def prune(client: OffloadClient) -> None:
    try:
        client.unlock()
        client.forget()
        client.prune()
    except Exception:
        client.unlock()
        raise
