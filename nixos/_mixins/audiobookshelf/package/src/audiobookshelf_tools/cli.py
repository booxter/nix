from __future__ import annotations

import argparse
import os
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

import httpx

from .api import AudiobookshelfError, HttpAudiobookshelfApi
from .reconcile import read_secret, read_settings, reconcile
from .systemd import SystemdUnitRestarter, UnitRestarter


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Reconcile Audiobookshelf settings and libraries")
    result.add_argument("--url", required=True)
    result.add_argument("--api-token-credential", required=True)
    result.add_argument("--client-secret-credential", required=True)
    result.add_argument("--settings-file", required=True)
    result.add_argument("--restart-unit", required=True)
    result.add_argument("--wait-seconds", type=float, default=120.0)
    return result


def credential_path(environment: Mapping[str, str], name: str) -> Path:
    directory = environment.get("CREDENTIALS_DIRECTORY")
    if directory is None:
        raise AudiobookshelfError("CREDENTIALS_DIRECTORY is not set")
    return Path(directory) / name


def client(base_url: str, api_token: str) -> httpx.Client:
    return httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {api_token}"},
        timeout=httpx.Timeout(30.0, connect=5.0),
        trust_env=False,
    )


def run(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    restarter: UnitRestarter,
    *,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> tuple[bool, bool, int]:
    args = parser().parse_args(arguments)
    api_token = read_secret(credential_path(environment, str(args.api_token_credential)))
    client_secret = read_secret(credential_path(environment, str(args.client_secret_credential)))
    settings = read_settings(Path(str(args.settings_file)))
    with client(str(args.url), api_token) as http_client:
        return reconcile(
            HttpAudiobookshelfApi(http_client),
            settings,
            client_secret,
            restarter,
            str(args.restart_unit),
            timeout=float(args.wait_seconds),
            interval=2.0,
            clock=clock,
            sleep=sleep,
        )


def main() -> None:
    try:
        oidc_changed, backups_changed, libraries_changed = run(
            sys.argv[1:],
            os.environ,
            SystemdUnitRestarter(),
            clock=time.monotonic,
            sleep=time.sleep,
        )
    except AudiobookshelfError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
    print(
        "Audiobookshelf reconciliation complete: "
        f"OIDC={'updated' if oidc_changed else 'unchanged'}, "
        f"backups={'updated' if backups_changed else 'unchanged'}, "
        f"libraries={libraries_changed} updated."
    )
