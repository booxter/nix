import argparse
import os
import sqlite3
from collections.abc import Sequence
from pathlib import Path

from curl_cffi import requests
from pydantic import ValidationError

from . import jellyfin
from .letterboxd import Letterboxd
from .models import Account, Config, SyncError
from .state import Cookies, State
from .sync import sync
from .transport import HttpTransport


def run(
    config: Config, account: Account, credentials: Path, directory: Path, *, dry_run: bool
) -> int:
    if config.jellyfin_url.scheme != "https":
        raise SyncError("Jellyfin must use HTTPS")

    state = State(directory, account.letterboxd_user)
    try:
        cookies = Cookies(credentials / "cookies", directory)
        token = (credentials / "jellyfin-key").read_text().strip()
        if not token:
            raise SyncError("The Jellyfin API key is empty")

        with jellyfin.connect(str(config.jellyfin_url), token) as source:
            movies = source.watched(account.jellyfin_user)

        with requests.Session(impersonate="firefox144", cookies=cookies.jar) as destination_session:
            destination = Letterboxd(
                HttpTransport("https://letterboxd.com", destination_session),
                account.letterboxd_user,
            )
            count = sync(movies, state, destination, dry_run=dry_run)
            # Persist rotated session cookies; a changed SOPS seed takes precedence next run.
            cookies.save()

        print(f"Watched movies with IMDb IDs: {len(movies)}; processed: {count}")
        return 0
    finally:
        state.close()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sync watched movies from Jellyfin to Letterboxd")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--credentials", type=Path, default=os.environ.get("CREDENTIALS_DIRECTORY"))
    parser.add_argument("--state", type=Path, default=os.environ.get("STATE_DIRECTORY"))
    parser.add_argument(
        "--dry-run", action="store_true", help="Upload and match only; do not import"
    )
    args = parser.parse_args(argv)
    if args.credentials is None or args.state is None:
        parser.error("--credentials and --state are required outside systemd")

    os.umask(0o077)
    try:
        config = Config.model_validate_json(args.config.read_text())
        account = Account.model_validate_json((args.credentials / "account").read_text())
        return run(config, account, args.credentials, args.state, dry_run=args.dry_run)
    except SyncError as error:
        print(f"Sync failed: {error}")
    except (ValidationError, ValueError):
        # Validation errors can contain the original secret values or remote HTML.
        print("Sync failed: invalid configuration, cookies, or remote response")
    except (OSError, sqlite3.Error):
        print("Sync failed: unable to read credentials or persist local state")
    return 1
