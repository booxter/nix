from __future__ import annotations

import argparse
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from enum import Enum
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Protocol, TextIO, cast

from dotenv import dotenv_values
from podman import PodmanClient
from podman.errors import ContainerError, PodmanError
from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError, field_validator
from requests import RequestException


class Error(RuntimeError):
    pass


class BindMount(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    source: Path
    target: str
    read_only: bool

    @field_validator("source")
    @classmethod
    def source_is_absolute(cls, source: Path) -> Path:
        if not source.is_absolute():
            raise ValueError("mount source must be absolute")
        return source

    @field_validator("target")
    @classmethod
    def target_is_absolute(cls, target: str) -> str:
        if not PurePosixPath(target).is_absolute():
            raise ValueError("mount target must be absolute")
        return target


class SetupConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    image: str = Field(min_length=1)
    environment: dict[str, str]
    mounts: tuple[BindMount, ...] = Field(min_length=1)


class SetupTask(Enum):
    MIGRATE = (
        "database migration",
        "/src/.venv/bin/alembic",
        ("upgrade", "head"),
    )
    INITIALIZE = (
        "startup initialization",
        "/src/.venv/bin/python3",
        ("startup.py",),
    )

    def __init__(self, label: str, executable: str, arguments: tuple[str, ...]) -> None:
        self.label = label
        self.executable = executable
        self.arguments = arguments


class SetupRuntime(Protocol):
    def run_task(
        self,
        task: SetupTask,
        config: SetupConfig,
        environment: Mapping[str, str],
        output: BinaryIO,
    ) -> None: ...


def _write_logs(logs: bytes | Iterable[bytes] | None, output: BinaryIO) -> None:
    if logs is None:
        return
    if isinstance(logs, bytes):
        output.write(logs)
        return
    for chunk in logs:
        output.write(chunk)


@dataclass
class PodmanSetupRuntime:
    client: PodmanClient

    @classmethod
    def connect(cls, socket_url: str) -> PodmanSetupRuntime:
        return cls(PodmanClient(base_url=socket_url, timeout=300))

    def close(self) -> None:
        self.client.api.close()

    def run_task(
        self,
        task: SetupTask,
        config: SetupConfig,
        environment: Mapping[str, str],
        output: BinaryIO,
    ) -> None:
        volumes = {
            str(mount.source): {
                "bind": mount.target,
                "mode": "ro" if mount.read_only else "rw",
            }
            for mount in config.mounts
        }
        try:
            # Resolve the image before run(): podman-py's convenience method
            # otherwise pulls a missing image, while this service must consume
            # the exact archive loaded by romm-prepare-assets.
            image = self.client.images.get(config.image)
            logs = self.client.containers.run(
                image,
                list(task.arguments),
                remove=True,
                stdout=True,
                stderr=True,
                cap_drop=["ALL"],
                entrypoint=[task.executable],
                environment=dict(environment),
                log_config={"Type": "journald"},
                network_mode="slirp4netns:allow_host_loopback=true",
                no_new_privileges=True,
                volumes=volumes,
                workdir="/backend",
            )
        except ContainerError as error:
            _write_logs(cast(bytes | Iterable[bytes] | None, error.stderr), output)
            raise Error(f"RomM {task.label} exited with status {error.exit_status}") from error
        except (PodmanError, RequestException, ValueError) as error:
            raise Error(f"failed to run RomM {task.label}") from error
        _write_logs(cast(bytes | Iterable[bytes] | None, logs), output)


def load_config(path: Path) -> SetupConfig:
    try:
        return SetupConfig.model_validate_json(path.read_text())
    except (OSError, ValidationError, ValueError) as error:
        raise Error(f"failed to load RomM setup configuration from {path}") from error


def load_environment(path: Path) -> dict[str, str]:
    try:
        values = dotenv_values(path, interpolate=False)
        return TypeAdapter(dict[str, str], config=ConfigDict(strict=True)).validate_python(values)
    except (OSError, ValidationError) as error:
        raise Error(f"failed to load RomM environment from {path}") from error


def setup_environment(config: SetupConfig, secrets: Mapping[str, str]) -> dict[str, str]:
    overlap = config.environment.keys() & secrets.keys()
    if overlap:
        names = ", ".join(sorted(overlap))
        raise Error(f"RomM secret environment overrides public configuration: {names}")
    return config.environment | dict(secrets)


def run_setup(
    runtime: SetupRuntime,
    config: SetupConfig,
    environment: Mapping[str, str],
    output: BinaryIO,
) -> None:
    runtime.run_task(SetupTask.MIGRATE, config, environment, output)
    runtime.run_task(SetupTask.INITIALIZE, config, environment, output)


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(
        description="Run RomM database migrations and startup initialization"
    )
    argument_parser.add_argument("--socket-url", required=True)
    argument_parser.add_argument("--config", type=Path, required=True)
    argument_parser.add_argument("--environment-file", type=Path, required=True)
    return argument_parser


def run(arguments: Sequence[str], output: BinaryIO, stderr: TextIO) -> int:
    options = parser().parse_args(arguments)
    runtime: PodmanSetupRuntime | None = None
    try:
        config = load_config(options.config)
        secrets = load_environment(options.environment_file)
        environment = setup_environment(config, secrets)
        runtime = PodmanSetupRuntime.connect(options.socket_url)
        run_setup(runtime, config, environment, output)
    except Error as error:
        print(f"romm-run-setup: {error}", file=stderr)
        return 1
    finally:
        if runtime is not None:
            runtime.close()
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], sys.stdout.buffer, sys.stderr))
