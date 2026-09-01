from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from .offload import OffloadFailure, prune
from .offload_cli import _SYSTEM_CLIENT_FACTORY, ClientFactory, load_client


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="restic-cloud-prune",
        description="Apply the retention policy to a cloud restic repository.",
    )
    command.add_argument("--config", required=True, type=Path)
    return command


def run(
    arguments: argparse.Namespace,
    client_factory: ClientFactory = _SYSTEM_CLIENT_FACTORY,
) -> int:
    prune(load_client(arguments, client_factory))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        return run(arguments)
    except (OSError, ValueError, OffloadFailure) as error:
        print(f"restic-cloud-prune: {error}", file=sys.stderr)
        return 1
