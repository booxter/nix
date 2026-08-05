from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from . import remote_scripts
from .models import Artifacts
from .process import Command, CommandRunner


class RemoteHba(Protocol):
    def preflight(self, controller: str) -> None: ...

    def stage(self, directory: str, artifacts: Artifacts) -> None: ...

    def check_tool(self, directory: str, controller: str) -> None: ...

    def quiesce(self) -> None: ...

    def verify_quiesced(self) -> None: ...

    def flash(self, directory: str, controller: str, with_optionrom: bool) -> None: ...

    def reboot(self) -> None: ...

    def cleanup(self, directory: str) -> None: ...


@dataclass(frozen=True)
class OpenSshRemoteHba:
    host: str
    runner: CommandRunner

    def _bash(self, script: str, *arguments: str) -> None:
        self.runner.run(Command(("ssh", self.host, "bash", "-s", "--", *arguments), stdin=script))

    def _copy(self, source: Path, destination: str) -> None:
        self.runner.run(Command(("scp", "-q", str(source), f"{self.host}:{destination}")))

    def preflight(self, controller: str) -> None:
        self._bash(remote_scripts.PREFLIGHT, controller)

    def stage(self, directory: str, artifacts: Artifacts) -> None:
        self.runner.run(Command(("ssh", self.host, f"mkdir -p '{directory}'")))
        self._copy(artifacts.sas3flash, f"{directory}/sas3flash")
        self._copy(artifacts.firmware, f"{directory}/firmware.bin")
        if artifacts.optionrom is not None:
            self._copy(artifacts.optionrom, f"{directory}/optionrom.rom")

    def check_tool(self, directory: str, controller: str) -> None:
        self._bash(remote_scripts.CHECK_TOOL, directory, controller)

    def quiesce(self) -> None:
        self._bash(remote_scripts.QUIESCE)

    def verify_quiesced(self) -> None:
        self._bash(remote_scripts.VERIFY_QUIESCED)

    def flash(self, directory: str, controller: str, with_optionrom: bool) -> None:
        self._bash(
            remote_scripts.FLASH,
            directory,
            controller,
            "1" if with_optionrom else "0",
        )

    def reboot(self) -> None:
        self.runner.run(Command(("ssh", self.host, "sudo systemctl reboot")))

    def cleanup(self, directory: str) -> None:
        self.runner.run(
            Command(
                ("ssh", self.host, f"rm -rf '{directory}'"),
                check=False,
                quiet=True,
            )
        )
