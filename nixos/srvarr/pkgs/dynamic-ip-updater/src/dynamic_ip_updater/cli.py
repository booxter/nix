from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import TextIO

from .app import DynamicIPClient, RejectedResponse, update

DEFAULT_URL = "https://t.myanonamouse.net/json/dynamicSeedbox.php"


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description="Update MyAnonamouse dynamic seedbox IP")
    argument_parser.add_argument("--cookie-jar", type=Path, required=True)
    argument_parser.add_argument("--url", default=DEFAULT_URL)
    argument_parser.add_argument("--timeout-seconds", type=float, default=30.0)
    return argument_parser


def run(arguments: Sequence[str], stdout: TextIO, stderr: TextIO) -> int:
    options = parser().parse_args(arguments)
    if options.timeout_seconds <= 0:
        print("timeout must be positive", file=stderr)
        return 2
    client = DynamicIPClient(url=options.url, timeout_seconds=options.timeout_seconds)
    try:
        response = update(options.cookie_jar, client)
    except RejectedResponse as error:
        print(error.body.decode("utf-8", errors="replace"), file=stderr)
        return 1
    except (OSError, ValueError) as error:
        print(error, file=stderr)
        return 1
    print(response.decode("utf-8", errors="replace"), file=stdout)
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], sys.stdout, sys.stderr))
