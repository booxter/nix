import argparse
from collections.abc import Sequence
from pathlib import Path

from pydantic import TypeAdapter

from .collector import collect
from .models import Target
from .source import CommandRunner, Source, TcSource


def main(argv: Sequence[str] | None = None, source: Source | None = None) -> int:
    parser = argparse.ArgumentParser(description="Export configured CAKE queues to Prometheus.")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    targets = TypeAdapter(list[Target]).validate_json(args.config.read_text())
    return 0 if collect(source or TcSource(CommandRunner()), targets, args.output) else 1
