from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import NoReturn, cast

from pydantic import BaseModel

from .contracts import ContractError, decode_case, decode_decision

Decoder = Callable[[bytes], BaseModel]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="media-repair-planner")
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("validate-case", "validate-decision"):
        command = commands.add_parser(name)
        command.add_argument("path", help="JSON file to validate, or - for standard input")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    command = cast(str, arguments.command)
    path = cast(str, arguments.path)
    decoder: Decoder = decode_case if command == "validate-case" else decode_decision
    try:
        payload = sys.stdin.buffer.read() if path == "-" else Path(path).read_bytes()
        decoder(payload)
    except (ContractError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


def entrypoint() -> NoReturn:
    raise SystemExit(main())
