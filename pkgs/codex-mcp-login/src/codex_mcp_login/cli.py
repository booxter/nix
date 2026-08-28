from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from typing import TextIO

from .app_server import StatusProbe, SubprocessStatusProbe
from .login import LoginRunner, SubprocessLoginRunner
from .workflow import LoginWorkflow


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="codex-mcp-login",
        description="Refresh usable MCP credentials and repair servers that require OAuth login.",
    )
    command.add_argument(
        "--server",
        action="append",
        default=[],
        dest="servers",
        metavar="NAME",
        help="configured OAuth MCP server to check (repeatable)",
    )
    command.add_argument(
        "--timeout-seconds",
        type=float,
        default=90.0,
        help="maximum time to wait for each app-server probe (default: 90)",
    )
    return command


def main(
    argv: Sequence[str] | None = None,
    *,
    probe: StatusProbe | None = None,
    login: LoginRunner | None = None,
    output: TextIO | None = None,
) -> int:
    command = parser()
    namespace = command.parse_args(argv if argv is not None else sys.argv[1:])
    if not namespace.servers:
        command.error("at least one --server is required")
    if namespace.timeout_seconds <= 0:
        command.error("--timeout-seconds must be positive")

    stream = output if output is not None else sys.stderr
    workflow = LoginWorkflow(
        probe=probe or SubprocessStatusProbe(timeout_seconds=namespace.timeout_seconds),
        login=login or SubprocessLoginRunner(),
        output=stream,
    )
    try:
        return workflow.run(namespace.servers)
    except KeyboardInterrupt:
        workflow.note("interrupted")
        return 130
