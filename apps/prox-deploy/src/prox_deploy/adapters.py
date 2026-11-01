from __future__ import annotations

import subprocess
from collections.abc import Callable, Iterator, Mapping, MutableMapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from importlib import import_module
from pathlib import Path
from typing import Protocol, cast

from .core import DeployRequest, ProxDeployError, ProxmoxCredentials


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    def run(
        self,
        arguments: Sequence[str],
        *,
        input_data: str | None = None,
        timeout: float | None = None,
    ) -> CommandResult: ...


class SubprocessRunner:
    def run(
        self,
        arguments: Sequence[str],
        *,
        input_data: str | None = None,
        timeout: float | None = None,
    ) -> CommandResult:
        try:
            result = subprocess.run(
                arguments,
                input=input_data,
                timeout=timeout,
                check=False,
                capture_output=True,
                text=True,
            )
        except subprocess.TimeoutExpired:
            return CommandResult(124, "", "command timed out")
        except OSError as error:
            raise ProxDeployError(f"cannot run {arguments[0]}: {error}") from error
        return CommandResult(result.returncode, result.stdout, result.stderr)


class PassPasswordStore:
    def __init__(self, executable: Path, runner: CommandRunner) -> None:
        self._executable = executable
        self._runner = runner

    def read(self, reference: str) -> str:
        result = self._runner.run([str(self._executable), "show", reference])
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit status {result.returncode}"
            raise ProxDeployError(f"failed to read password-store entry {reference}: {detail}")

        if not result.stdout.strip():
            raise ProxDeployError(f"password-store entry is empty: {reference}")
        # Keep the terminating newline required by OpenSSH private keys.
        return result.stdout


class NixmoxerCallback(Protocol):
    def __call__(self, flake: bool, machine: str, node: str | None = None) -> object: ...


def load_nixmoxer_callback() -> NixmoxerCallback:
    # nixmoxer currently installs an unnamespaced `main` module and does not
    # expose a supported library API. Fix this in the upstream package; keep
    # the compatibility boundary isolated here until then.
    return cast(NixmoxerCallback, import_module("main").bootstrap.callback)


class NixmoxerDeployer:
    def __init__(
        self,
        callback_loader: Callable[[], NixmoxerCallback],
        environment: MutableMapping[str, str],
    ) -> None:
        self._callback_loader = callback_loader
        self._environment = environment

    def deploy(self, request: DeployRequest, credentials: ProxmoxCredentials) -> int:
        with _temporary_environment(
            self._environment,
            credentials.as_nixmoxer_environment(),
        ):
            vmid = self._callback_loader()(True, request.vm_type, request.node)
        if type(vmid) is not int or not 100 <= vmid <= 999999999:
            raise ProxDeployError("nixmoxer did not return a valid created VM ID")
        return vmid


@contextmanager
def _temporary_environment(
    environment: MutableMapping[str, str],
    values: Mapping[str, str],
) -> Iterator[None]:
    previous = {key: environment.get(key) for key in values}
    environment.update(values)
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
