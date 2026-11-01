from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

import httpx2
from pydantic import ValidationError
from vikunja_provision.api import HttpVikunja
from vikunja_provision.login import AuthorizationPrompt, login
from vikunja_provision.models import Declaration, ProvisionError, Report
from vikunja_provision.storage import FileCredentials, read_session
from vikunja_provision.workflow import apply, plan


class ConsoleAuthorizationPrompt:
    def show(self, url: str) -> None:
        print(f"Open this URL to sign in through Vikunja SSO:\n{url}", file=sys.stderr)


def run(argv: Sequence[str] | None = None, *, prompt: AuthorizationPrompt | None = None) -> int:
    parser = argparse.ArgumentParser(description="Reconcile a Vikunja bot and its MCP access")
    parser.add_argument("operation", choices=("plan", "apply"))
    parser.add_argument("--config", type=Path, required=True, help="JSON declaration")
    parser.add_argument(
        "--session-token-file",
        type=Path,
        help="Use an existing private user-session JWT instead of SSO",
    )
    parser.add_argument(
        "--credentials-file", type=Path, required=True, help="Private bot token state"
    )
    parser.add_argument(
        "--rotate-token", action="store_true", help="Replace and revoke the old token"
    )
    args = parser.parse_args(argv)

    try:
        desired = Declaration.model_validate_json(args.config.read_text(encoding="utf-8"))
        session = (
            read_session(args.session_token_file)
            if args.session_token_file is not None
            else login(desired.server_url, prompt or ConsoleAuthorizationPrompt())
        )
        store = FileCredentials(args.credentials_file)
        with store.locked(), httpx2.Client(timeout=20) as client:
            api = HttpVikunja(client, desired.server_url, session)
            prepared = plan(
                desired,
                api,
                store,
                rotate_token=args.rotate_token,
                now=datetime.now(UTC),
            )
            if args.operation == "apply":
                apply(desired, prepared, api, store)

        print(Report(changes=prepared.changes).model_dump_json(indent=2))
    except ValidationError as error:
        print("Invalid declaration:", file=sys.stderr)
        for detail in error.errors(include_input=False, include_context=False):
            location = ".".join(str(part) for part in detail["loc"]) or "declaration"
            print(f"  {location}: {detail['msg']}", file=sys.stderr)
        return 1
    except (OSError, ProvisionError) as error:
        print(f"vikunja-provision: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("vikunja-provision: interrupted", file=sys.stderr)
        return 130

    return 0


def main() -> None:
    raise SystemExit(run())
