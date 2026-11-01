from __future__ import annotations

import shlex
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TextIO

from proxmox_bootstrap.identity import RECEIVER
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .adapters import CommandResult, CommandRunner
from .core import DeployRequest, ProxDeployError


class Clock(Protocol):
    def now(self) -> float: ...

    def sleep(self, seconds: float) -> None: ...


class SystemClock:
    def now(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


class GuestExecution(BaseModel):
    # qm decodes guest output and converts QGA booleans to integers.
    model_config = ConfigDict(strict=True)

    exited: int = Field(default=0, ge=0, le=1)
    exitcode: int | None = None
    error: str = Field(default="", alias="err-data")


def ping_arguments(vmid: int) -> list[str]:
    return ["guest", "cmd", str(vmid), "ping"]


def receiver_arguments(vmid: int) -> list[str]:
    return ["guest", "exec", str(vmid), "--pass-stdin", "--timeout", "60", "--", RECEIVER]


@dataclass
class SshGuestInstaller:
    ssh: Path
    runner: CommandRunner
    clock: Clock
    stderr: TextIO

    def prepare(self, request: DeployRequest) -> None:
        # sudo -l checks permissions without executing either operation on VM 100.
        # Do this before nixmoxer can replace an existing VM.
        for arguments in (ping_arguments(100), receiver_arguments(100)):
            command = shlex.join(
                [
                    "/run/wrappers/bin/sudo",
                    "-n",
                    "-l",
                    "--",
                    "/run/current-system/sw/bin/qm",
                    *arguments,
                ]
            )
            result = self._ssh(request.node, command)
            if result.returncode != 0:
                raise ProxDeployError(
                    f"cannot use the guest agent on {request.node}: {result.stderr.strip()}"
                )

    def _ssh(
        self,
        host: str,
        command: str,
        *,
        input_data: str | None = None,
        timeout: float = 60,
    ) -> CommandResult:
        return self.runner.run(
            [
                str(self.ssh),
                "-T",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "StrictHostKeyChecking=yes",
                "--",
                host,
                command,
            ],
            input_data=input_data,
            timeout=timeout,
        )

    def _qm(
        self,
        node: str,
        arguments: Sequence[str],
        *,
        input_data: str | None = None,
        timeout: float = 60,
    ) -> CommandResult:
        # OpenSSH's remote command is shell text. Only these quoted arguments
        # cross that boundary; private key material travels over stdin.
        command = shlex.join(
            ["/run/wrappers/bin/sudo", "-n", "/run/current-system/sw/bin/qm", *arguments]
        )
        return self._ssh(node, command, input_data=input_data, timeout=timeout)

    def _wait(self, check: Callable[[], CommandResult], description: str, timeout: float) -> None:
        print(description, file=self.stderr)
        deadline = self.clock.now() + timeout
        while True:
            result = check()
            if result.returncode == 0:
                return
            if self.clock.now() >= deadline:
                detail = (
                    result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
                )
                raise ProxDeployError(f"{description}: {detail}")
            self.clock.sleep(1)

    def install(self, request: DeployRequest, vmid: int, identity: bytes) -> None:
        self._wait(
            lambda: self._qm(request.node, ping_arguments(vmid)),
            f"Waiting for {request.vm_type}'s installer on {request.node}",
            120,
        )
        result = self._qm(
            request.node,
            receiver_arguments(vmid),
            input_data=identity.decode(),
            timeout=90,
        )
        if result.returncode != 0:
            raise ProxDeployError(f"cannot deliver installation identity: {result.stderr.strip()}")
        try:
            execution = GuestExecution.model_validate_json(result.stdout)
        except ValidationError as error:
            raise ProxDeployError("invalid response from the guest identity receiver") from error
        if execution.exited != 1 or execution.exitcode != 0:
            detail = execution.error.strip() or "receiver did not complete successfully"
            raise ProxDeployError(f"guest identity receiver failed: {detail}")

        self._wait(
            lambda: self._ssh(request.vm_type, "systemctl is-active sops-install-secrets.service"),
            f"Waiting for {request.vm_type} to finish installation and decrypt its secrets",
            900,
        )
