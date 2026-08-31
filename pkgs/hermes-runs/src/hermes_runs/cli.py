from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence
from datetime import datetime
from typing import TextIO

from .client import Client, HermesClient, HermesError, HermesHttpError, JsonObject


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Control and monitor Hermes Agent runs")
    subparsers = result.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run", help="start a run and print its ID")
    run.add_argument("input", help="instruction for the agent")

    list_runs = subparsers.add_parser("list", help="list recent runs")
    list_runs.add_argument("--limit", type=int, default=20)

    watch = subparsers.add_parser("watch", help="follow a run's event stream")
    watch.add_argument("run_id")

    status = subparsers.add_parser("status", help="show a run's current state")
    status.add_argument("run_id")
    status.add_argument("--json", action="store_true", help="print the raw API response")

    approve = subparsers.add_parser("approve", help="answer a pending approval")
    approve.add_argument("run_id")
    approve.add_argument("choice", choices=("once", "session", "always", "deny"))
    approve.add_argument("--all", action="store_true", help="resolve all pending approvals")

    stop = subparsers.add_parser("stop", help="stop a run")
    stop.add_argument("run_id")
    return result


def _json(value: JsonObject, output: TextIO) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True), file=output)


def _status(value: JsonObject, output: TextIO) -> None:
    run_id = value.get("run_id", "unknown run")
    status = value.get("status", "unknown")
    model = value.get("model")
    heading = f"{run_id}: {status}"
    if model:
        heading += f" ({model})"
    print(heading, file=output)

    last_event = value.get("last_event")
    if last_event:
        print(f"last event: {last_event}", file=output)

    error = value.get("error")
    if error:
        print(f"\nerror:\n{error}", file=output)

    final_output = value.get("output")
    if final_output:
        print(f"\n{final_output}", file=output)

    usage = value.get("usage")
    if isinstance(usage, dict) and usage:
        print(f"\nusage: {json.dumps(usage, ensure_ascii=False, sort_keys=True)}", file=output)


def _list(client: Client, limit: int, output: TextIO) -> None:
    runs = client.list_runs(limit)
    if not runs:
        print("no runs found", file=output)
        return

    print(
        f"{'RUN ID':36}  {'STATUS':12}  {'LAST ACTIVE':19}  {'MODEL':24}  PREVIEW",
        file=output,
    )
    for summary in runs:
        last_active = "-"
        if summary.last_active is not None:
            last_active = datetime.fromtimestamp(summary.last_active).astimezone().strftime("%F %T")
        preview = summary.preview.replace("\n", " ")
        model = summary.model[:24]
        print(
            f"{summary.run_id:36}  {summary.status:12}  {last_active:19}  {model:24}  {preview}",
            file=output,
        )


def _watch(client: Client, run_id: str, output: TextIO) -> None:
    in_message = False
    saw_message = False
    try:
        for event in client.watch_run(run_id):
            event_name = str(event.get("event", "event"))
            if event_name == "message.delta":
                print(str(event.get("delta", "")), end="", flush=True, file=output)
                in_message = True
                saw_message = True
                continue

            if in_message:
                print(file=output)
                in_message = False

            details = {
                key: value
                for key, value in event.items()
                if key not in {"event", "run_id", "timestamp"}
            }
            if event_name == "run.completed":
                final_output = details.pop("output", None)
                if not saw_message and isinstance(final_output, str) and final_output:
                    print(final_output, file=output)
            suffix = (
                f" {json.dumps(details, ensure_ascii=False, sort_keys=True)}" if details else ""
            )
            print(f"[{event_name}]{suffix}", flush=True, file=output)
    except HermesHttpError as error:
        if error.status != 404:
            raise
        print("event stream is no longer available; showing retained status\n", file=output)
        _status(client.get_run(run_id), output)

    if in_message:
        print(file=output)


def run(
    argv: Sequence[str],
    environment: Mapping[str, str],
    output: TextIO,
    client: Client | None = None,
) -> int:
    args = parser().parse_args(argv)
    if client is None:
        api_key = environment.get("HERMES_API_KEY")
        if not api_key:
            raise HermesError("HERMES_API_KEY is not set")
        client = HermesClient(environment.get("HERMES_API", "http://127.0.0.1:8642"), api_key)

    if args.command == "run":
        print(client.start_run(args.input), file=output)
    elif args.command == "list":
        _list(client, args.limit, output)
    elif args.command == "watch":
        _watch(client, args.run_id, output)
    elif args.command == "status":
        response = client.get_run(args.run_id)
        if args.json:
            _json(response, output)
        else:
            _status(response, output)
    elif args.command == "approve":
        _json(client.approve_run(args.run_id, args.choice, args.all), output)
    elif args.command == "stop":
        _json(client.stop_run(args.run_id), output)
    return 0


def main() -> None:  # pragma: no cover - console entry point
    try:
        raise SystemExit(run(sys.argv[1:], os.environ, sys.stdout))
    except HermesError as error:
        print(f"hermes-runs: {error}", file=sys.stderr)
        raise SystemExit(1) from error
