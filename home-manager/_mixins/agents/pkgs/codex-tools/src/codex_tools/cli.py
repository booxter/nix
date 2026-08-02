import argparse
import json
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import TextIO

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient, UrllibJsonHttpClient
from codex_tools.usage import PersonalUsageService, format_personal_usage
from codex_tools.work_usage import WorkUsageService, format_work_usage


def _usage_parser(default_auth_file: Path) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="codex-usage-status",
        description="Print Codex rate-limit state from the local Codex OAuth session.",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", dest="output_format", action="store_const", const="json")
    output.add_argument("--text", dest="output_format", action="store_const", const="text")
    parser.set_defaults(output_format="text")
    parser.add_argument("--auth-file", type=Path, default=default_auth_file)
    return parser


def _work_usage_parser(default_auth_file: Path) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="codex-work-usage-status",
        description="Print Codex work-account credit usage from the local OAuth session.",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", dest="output_format", action="store_const", const="json")
    output.add_argument("--text", dest="output_format", action="store_const", const="text")
    parser.set_defaults(output_format="text")
    parser.add_argument("--auth-file", type=Path, default=default_auth_file)
    return parser


def usage_main(
    argv: Sequence[str] | None = None,
    *,
    client: JsonHttpClient | None = None,
    now: float | None = None,
    home: Path | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    default_auth_file = (home or Path.home()) / ".codex" / "auth.json"
    args = _usage_parser(default_auth_file).parse_args(argv)
    try:
        auth = CodexAuth.load(args.auth_file)
        usage = PersonalUsageService(client or UrllibJsonHttpClient()).fetch(
            auth,
            now=time.time() if now is None else now,
        )
    except CodexToolsError as error:
        print(error, file=stderr)
        return 1

    if args.output_format == "json":
        print(json.dumps(usage.to_json(), separators=(",", ":")), file=stdout)
    else:
        print(format_personal_usage(usage), file=stdout)
    return 0


def work_usage_main(
    argv: Sequence[str] | None = None,
    *,
    client: JsonHttpClient | None = None,
    now: float | None = None,
    home: Path | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    default_auth_file = (home or Path.home()) / ".codex" / "auth.json"
    args = _work_usage_parser(default_auth_file).parse_args(argv)
    try:
        auth = CodexAuth.load(args.auth_file)
        if not auth.account_id:
            raise CodexToolsError(f"No account id found in {args.auth_file}")
        usage = WorkUsageService(client or UrllibJsonHttpClient()).fetch(
            auth,
            now=time.time() if now is None else now,
        )
    except CodexToolsError as error:
        print(error, file=stderr)
        return 1

    if args.output_format == "json":
        print(json.dumps(usage.to_json(), separators=(",", ":")), file=stdout)
    else:
        print(format_work_usage(usage), file=stdout)
    return 0
