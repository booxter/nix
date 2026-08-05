from __future__ import annotations

import argparse
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .clients import SubprocessRunner, b2_environment, system_environment
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


def _read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def run(
    arguments: argparse.Namespace,
    client_factory: ClientFactory = SystemClientFactory(),
) -> int:
    config = OffloadConfig.model_validate_json(arguments.config.read_text(encoding="utf-8"))
    environment = b2_environment(
        system_environment(),
        application_key_id=_read_secret(config.b2_application_key_id_file),
        application_key=_read_secret(config.b2_application_key_file),
    )
    offload(client_factory(config, environment))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        return run(arguments)
    except (OSError, ValueError, OffloadFailure) as error:
        print(f"restic-cloud-offload: {error}", file=sys.stderr)
        return 1
