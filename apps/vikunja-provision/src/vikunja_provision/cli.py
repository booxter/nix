from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

import httpx2
from pydantic import ValidationError
from sops_tools.cli import Application
from sops_tools.errors import ToolError
from vikunja_provision.api import HttpVikunja
from vikunja_provision.distribution import TokenDistribution
from vikunja_provision.login import AuthorizationPrompt, login
from vikunja_provision.models import Declarations, ProvisionError, Report
from vikunja_provision.storage import (
    SecretStore,
    SopsCredentials,
    SopsSecrets,
    provision_lock,
    read_session,
)
from vikunja_provision.workflow import apply, plan


class ConsoleAuthorizationPrompt:
    def show(self, url: str) -> None:
        print(f"Open this URL to sign in through Vikunja SSO:\n{url}", file=sys.stderr)


def run(
    argv: Sequence[str] | None = None,
    *,
    prompt: AuthorizationPrompt | None = None,
    secrets: SecretStore | None = None,
) -> int:
    parser = argparse.ArgumentParser(description="Reconcile a Vikunja bot and its MCP access")
    parser.add_argument("host", help="Host carrying the Vikunja declaration")
    parser.add_argument("bot", help="Bot name in host.vikunja.bots")
    parser.add_argument(
        "--declarations-file",
        type=Path,
        default=os.environ.get("VIKUNJA_DECLARATIONS_FILE"),
        help="Override the declarations generated from the Nix configuration",
    )
    parser.add_argument(
        "--session-token-file",
        type=Path,
        help="Use an existing private user-session JWT instead of SSO",
    )
    parser.add_argument(
        "--rotate-token", action="store_true", help="Replace and revoke the old token"
    )
    args = parser.parse_args(argv)
    if args.declarations_file is None:
        parser.error("Run the packaged app or supply --declarations-file")

    try:
        declarations = Declarations.model_validate_json(
            args.declarations_file.read_text(encoding="utf-8")
        )
        desired = declarations.select(args.host, args.bot)
        secret_store = secrets or SopsSecrets(Application.discover())
        store = SopsCredentials(desired.state, secret_store)
        distribution = TokenDistribution(desired.seats, secret_store)
        session = (
            read_session(args.session_token_file)
            if args.session_token_file is not None
            else login(desired.server_url, prompt or ConsoleAuthorizationPrompt())
        )
        with (
            provision_lock(desired.server_url, desired.bot.username),
            httpx2.Client(timeout=20) as client,
        ):
            api = HttpVikunja(client, desired.server_url, session)
            prepared = plan(
                desired,
                api,
                store,
                rotate_token=args.rotate_token,
                now=datetime.now(UTC),
            )
            changes = list(prepared.changes)
            changes.extend(
                distribution.plan(None if prepared.issue_token else prepared.credentials)
            )
            apply(desired, prepared, api, store, distribution)

        print(Report(changes=changes).model_dump_json(indent=2))
    except ValidationError as error:
        print("Invalid declaration:", file=sys.stderr)
        for detail in error.errors(include_input=False, include_context=False):
            location = ".".join(str(part) for part in detail["loc"]) or "declaration"
            print(f"  {location}: {detail['msg']}", file=sys.stderr)
        return 1
    except (OSError, ProvisionError, ToolError) as error:
        print(f"vikunja-provision: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("vikunja-provision: interrupted", file=sys.stderr)
        return 130

    return 0


def main() -> None:
    raise SystemExit(run())
