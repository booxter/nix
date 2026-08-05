from __future__ import annotations

import argparse
import sys
import time
from datetime import date
from pathlib import Path
from typing import TextIO

from .metrics import hold_description, write_hold_metrics, write_success_metric
from .model import UpgradeConfig
from .reboot import ShutdownCommand, schedule_reboot_if_needed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage NixOS auto-upgrade lifecycle state.")
    commands = parser.add_subparsers(dest="command", required=True)

    guard = commands.add_parser("guard", help="reject maintenance during an active hold")
    guard.add_argument("--config", required=True, type=Path)

    holds = commands.add_parser("write-hold-metrics", help="export the current hold state")
    holds.add_argument("--config", required=True, type=Path)
    holds.add_argument("--output", required=True, type=Path)

    success = commands.add_parser("write-success-metric", help="record a successful upgrade")
    success.add_argument("--output", required=True, type=Path)

    reboot = commands.add_parser("reboot-if-needed", help="schedule a reboot for a changed system")
    reboot.add_argument("--shutdown-executable", required=True, type=Path)
    return parser


def guard(config: UpgradeConfig, today: date, stderr: TextIO) -> int:
    hold = config.active_hold(today)
    if hold is None:
        return 0
    print(hold_description(config.hostname, today, hold), file=stderr)
    return 1


def run(arguments: list[str], stderr: TextIO = sys.stderr) -> int:
    args = build_parser().parse_args(arguments)
    today = date.today()
    if args.command == "guard":
        return guard(UpgradeConfig.load(args.config), today, stderr)
    if args.command == "write-hold-metrics":
        write_hold_metrics(args.output, UpgradeConfig.load(args.config), today)
        return 0
    if args.command == "write-success-metric":
        write_success_metric(args.output, int(time.time()))
        return 0
    if args.command == "reboot-if-needed":
        changed = schedule_reboot_if_needed(ShutdownCommand(args.shutdown_executable))
        if changed:
            print(
                "Booted kernel, initrd, or modules differ from the current system profile; "
                "scheduling reboot."
            )
        else:
            print(
                "Booted kernel, initrd, and modules match the current system profile; no reboot needed."
            )
        return 0
    raise AssertionError(f"unhandled command {args.command}")


def main() -> None:
    try:
        status = run(sys.argv[1:])
    except (OSError, ValueError) as error:
        print(f"auto-upgrade-tools: {error}", file=sys.stderr)
        status = 1
    raise SystemExit(status)
