from __future__ import annotations

import argparse
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .clients import SubprocessRunner, cloud_environment, system_environment
from .models import OffloadConfig
from .offload import OffloadClient, OffloadFailure, ResticOffloadClient, offload


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="restic-cloud-offload",
        description="Copy a local restic repository into its cloud repository.",
    )
    command.add_argument("--config", required=True, type=Path)
    return command


class ClientFactory(Protocol):
    def __call__(
        self,
        config: OffloadConfig,
        environment: Mapping[str, str],
    ) -> OffloadClient: ...


@dataclass(frozen=True)
class SystemClientFactory:
    def __call__(
        self,
        config: OffloadConfig,
        environment: Mapping[str, str],
    ) -> OffloadClient:
        return ResticOffloadClient(config, SubprocessRunner(), environment)


_SYSTEM_CLIENT_FACTORY: ClientFactory = SystemClientFactory()


def _read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def run(
    arguments: argparse.Namespace,
    client_factory: ClientFactory = _SYSTEM_CLIENT_FACTORY,
) -> int:
    offload(load_client(arguments, client_factory))
    return 0


def load_client(
    arguments: argparse.Namespace,
    client_factory: ClientFactory = _SYSTEM_CLIENT_FACTORY,
) -> OffloadClient:
    config = OffloadConfig.model_validate_json(arguments.config.read_text(encoding="utf-8"))
    if config.application_key_id_file is None and config.application_key_file is None:
        environment = system_environment()
    elif config.application_key_id_file is not None and config.application_key_file is not None:
        environment = cloud_environment(
            system_environment(),
            application_key_id=_read_secret(config.application_key_id_file),
            application_key=_read_secret(config.application_key_file),
        )
    else:
        raise ValueError("both cloud application key files must be configured together")
    return client_factory(config, environment)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        return run(arguments)
    except (OSError, ValueError, OffloadFailure) as error:
        print(f"restic-cloud-offload: {error}", file=sys.stderr)
        return 1
