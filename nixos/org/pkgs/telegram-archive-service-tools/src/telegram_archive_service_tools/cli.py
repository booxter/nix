from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from pydantic import ValidationError

from telegram_archive_service_tools.credentials import (
    apply,
    from_systemd_directory,
    read_credentials,
)
from telegram_archive_service_tools.model import AuthConfig
from telegram_archive_service_tools.runtime import Error, Executor, OsExecutor, launch
from telegram_archive_service_tools.systemd import PystemdUnitState, UnitState

DEFAULT_AUTH_CONFIG = Path("/etc/telegram-archive/auth.json")


def service_parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("executable", type=Path)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser


def credential_directory(environment: Mapping[str, str]) -> Path:
    value = environment.get("CREDENTIALS_DIRECTORY")
    if not value:
        raise Error("systemd credentials are required")
    return Path(value)


def run_service(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    stderr: TextIO,
    executor: Executor,
    *,
    telegram: bool,
) -> int:
    description = (
        "Run the Telegram Archive scheduler" if telegram else "Run Telegram Archive viewer"
    )
    options = service_parser(description).parse_args(arguments)
    try:
        credentials = from_systemd_directory(credential_directory(environment), telegram=telegram)
        child_environment = dict(environment)
        apply(child_environment, credentials)
        launch(options.executable, options.arguments, child_environment, executor)
    except Error as error:
        print(f"telegram-archive: {error}", file=stderr)
        return 1
    return 0


def load_auth_config(path: Path) -> AuthConfig:
    try:
        return AuthConfig.model_validate_json(path.read_text())
    except (OSError, ValidationError, ValueError) as error:
        raise Error(f"failed to load Telegram Archive auth configuration from {path}") from error


def auth_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Authenticate Telegram Archive interactively")
    parser.add_argument("--config", type=Path, default=DEFAULT_AUTH_CONFIG)
    return parser


def run_auth(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    stderr: TextIO,
    executor: Executor,
    units: UnitState,
) -> int:
    options = auth_parser().parse_args(arguments)
    try:
        config = load_auth_config(options.config)
        if units.is_active(config.scheduler_unit):
            raise Error(f"{config.scheduler_unit} is running; stop it before authenticating")
        credentials = read_credentials(config.credentials, telegram=True)
        child_environment = dict(environment)
        child_environment.update(config.environment)
        apply(child_environment, credentials)
        launch(
            config.executable,
            ("auth",),
            child_environment,
            executor,
            user=config.user,
            working_directory=config.state_directory,
            umask=0o077,
        )
    except Error as error:
        print(f"telegram-archive-auth: {error}", file=stderr)
        return 1
    return 0


def scheduler_main() -> None:  # pragma: no cover
    raise SystemExit(run_service(sys.argv[1:], os.environ, sys.stderr, OsExecutor(), telegram=True))


def viewer_main() -> None:  # pragma: no cover
    raise SystemExit(
        run_service(sys.argv[1:], os.environ, sys.stderr, OsExecutor(), telegram=False)
    )


def auth_main() -> None:  # pragma: no cover
    raise SystemExit(
        run_auth(sys.argv[1:], os.environ, sys.stderr, OsExecutor(), PystemdUnitState())
    )
