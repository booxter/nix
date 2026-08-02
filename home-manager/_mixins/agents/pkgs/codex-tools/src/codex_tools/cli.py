import argparse
import json
import os
import sys
import time
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient, UrllibJsonHttpClient
from codex_tools.reset_credits import ResetCreditsService, format_reset_credits
from codex_tools.usage import PersonalUsageService, format_personal_usage
from codex_tools.warmer import (
    RESPONSES_ENDPOINT,
    OpenAIResponsesClient,
    ResponsesClient,
    WarmerService,
)
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


def reset_credits_main(
    argv: Sequence[str] | None = None,
    *,
    client: JsonHttpClient | None = None,
    home: Path | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = argparse.ArgumentParser(
        prog="codex-rate-limit-reset-credits",
        description="Print Codex rate-limit reset credits.",
    )
    parser.add_argument(
        "auth_file",
        nargs="?",
        type=Path,
        default=(home or Path.home()) / ".codex" / "auth.json",
    )
    args = parser.parse_args(argv)
    try:
        report = ResetCreditsService(client or UrllibJsonHttpClient()).fetch(
            CodexAuth.load(args.auth_file)
        )
    except CodexToolsError as error:
        print(error, file=stderr)
        return 1
    print(format_reset_credits(report), file=stdout)
    return 0


def warmer_main(
    argv: Sequence[str] | None = None,
    *,
    client: JsonHttpClient | None = None,
    responses_client: ResponsesClient | None = None,
    now: float | None = None,
    home: Path | None = None,
    environ: Mapping[str, str] | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = argparse.ArgumentParser(
        prog="codex-warmer",
        description="Start the Codex five-hour usage window when it is inactive.",
    )
    parser.add_argument(
        "--auth-file",
        type=Path,
        default=(home or Path.home()) / ".codex" / "auth.json",
    )
    args = parser.parse_args(argv)
    environment = os.environ if environ is None else environ
    http_client = client or UrllibJsonHttpClient()
    try:
        started = WarmerService(
            PersonalUsageService(http_client),
            responses_client or OpenAIResponsesClient(),
            responses_endpoint=environment.get(
                "CODEX_WARMER_RESPONSES_ENDPOINT",
                RESPONSES_ENDPOINT,
            ),
        ).warm_if_needed(
            CodexAuth.load(args.auth_file),
            now=time.time() if now is None else now,
        )
    except CodexToolsError as error:
        print(error, file=stderr)
        return 1
    if started:
        print("Started the Codex five-hour usage window.", file=stdout)
    return 0
