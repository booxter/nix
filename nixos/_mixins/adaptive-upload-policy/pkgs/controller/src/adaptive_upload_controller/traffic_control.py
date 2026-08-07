from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import subprocess
from typing import Protocol

from .errors import ControllerError


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str]) -> None: ...


class TrafficControl(Protocol):
    def apply_rate(self, rate_mbit: float) -> None: ...


@dataclass(frozen=True)
class SubprocessRunner:
    def run(self, arguments: Sequence[str]) -> None:
        try:
            subprocess.run(
                list(arguments),
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as error:
            stderr = error.stderr.strip()
            detail = f": {stderr}" if stderr else ""
            raise ControllerError(f"qosctl failed{detail}") from error
        except OSError as error:
            raise ControllerError(f"failed to execute qosctl: {error}") from error


@dataclass(frozen=True)
class QosctlTrafficControl:
    executable: str
    config_file: str
    limit: str
    runner: CommandRunner

    def apply_rate(self, rate_mbit: float) -> None:
        self.runner.run(
            [
                self.executable,
                "--config",
                self.config_file,
                "--limit",
                self.limit,
                "--rate-mbit",
                f"{rate_mbit:g}",
                "set-rate",
            ]
        )
