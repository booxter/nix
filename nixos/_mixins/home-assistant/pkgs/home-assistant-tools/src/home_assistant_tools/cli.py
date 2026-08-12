from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Sequence
from pathlib import Path

from .auth import LocalAuthenticator
from .backup import BackupManager
from .bootstrap import Bootstrapper
from .errors import HomeAssistantError
from .http import HttpxHomeAssistantApi
from .models import AuthenticationConfig, BackupConfig, BootstrapConfig
from .websocket import WebsocketBackupSessionFactory


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="home-assistant-tools",
        description="Bootstrap and back up the fleet Home Assistant instance.",
    )
    subcommands = command.add_subparsers(dest="operation", required=True)

    def add_authentication(arguments: argparse.ArgumentParser) -> None:
        arguments.add_argument("--base-url", required=True)
        arguments.add_argument("--client-id", required=True)
        arguments.add_argument("--owner-username", required=True)
        arguments.add_argument("--password-file", required=True, type=Path)

    bootstrap = subcommands.add_parser("bootstrap", help="complete initial onboarding")
    add_authentication(bootstrap)
    bootstrap.add_argument("--owner-display-name", required=True)
    bootstrap.add_argument("--owner-language", required=True)

    backup = subcommands.add_parser("backup", help="create and retain native backups")
    add_authentication(backup)
    backup.add_argument("--keep-backups", type=int, default=7)
    return command


def authentication(namespace: argparse.Namespace) -> AuthenticationConfig:
    return AuthenticationConfig(
        base_url=namespace.base_url,
        client_id=namespace.client_id,
        owner_username=namespace.owner_username,
        password_file=namespace.password_file,
    )


async def run(namespace: argparse.Namespace) -> None:
    auth_config = authentication(namespace)
    async with HttpxHomeAssistantApi(auth_config.base_url) as api:
        authenticator = LocalAuthenticator(api)
        if namespace.operation == "bootstrap":
            await Bootstrapper(api, authenticator).run(
                BootstrapConfig(
                    authentication=auth_config,
                    owner_display_name=namespace.owner_display_name,
                    owner_language=namespace.owner_language,
                )
            )
        else:
            await BackupManager(
                authenticator,
                WebsocketBackupSessionFactory(auth_config.base_url),
            ).run(BackupConfig(auth_config, keep_backups=namespace.keep_backups))


def main(argv: Sequence[str] | None = None) -> int:
    namespace = parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        asyncio.run(run(namespace))
    except (HomeAssistantError, OSError, TimeoutError) as error:
        print(f"home-assistant-tools: {error}", file=sys.stderr)
        return 1
    return 0
