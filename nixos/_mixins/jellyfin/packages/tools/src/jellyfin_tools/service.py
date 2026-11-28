from __future__ import annotations

import shutil
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import TextIO

from .api import JellyfinApiError
from .models import Session
from .systemd import UnitState


class JellyfinServiceError(RuntimeError):
    pass


@dataclass(frozen=True)
class BackupResult:
    destination: Path
    removed_staging: tuple[Path, ...]
    removed_source: tuple[Path, ...]


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def blocks_maintenance(session: Session, now: datetime) -> bool:
    if session.now_playing_item is None:
        return False

    if not session.play_state.is_paused or session.last_paused_date is None:
        return True

    # Client check-ins can continue indefinitely while playback stays paused.
    return now - session.last_paused_date < timedelta(minutes=60)


def wait_for_idle(
    unit_state: UnitState,
    load_sessions: Callable[[], tuple[Session, ...]],
    *,
    unit_name: str,
    interval: float,
    now: Callable[[], datetime],
    sleep: Callable[[float], None],
    stderr: TextIO,
) -> None:
    while unit_state.is_active(unit_name):
        try:
            checked_at = now()
            sessions = tuple(
                session for session in load_sessions() if blocks_maintenance(session, checked_at)
            )
        except JellyfinApiError:
            print(
                f"Unable to query active Jellyfin sessions; retrying in {interval:g}s.",
                file=stderr,
            )
            sleep(interval)
            continue

        if not sessions:
            print("No Jellyfin playback requires a maintenance hold.")
            return

        print(
            f"Holding maintenance for {len(sessions)} active Jellyfin playback session(s):",
            file=stderr,
        )
        for session in sessions:
            item = session.now_playing_item
            assert item is not None
            state = "paused" if session.play_state.is_paused else "playing"
            print(f"  - {session.user_name}: {item.name} ({state})", file=stderr)
        print(
            f"Retrying in {interval:g}s. Use deploy --no-inhibit to override a manual deployment.",
            file=stderr,
        )
        sleep(interval)

    print("Jellyfin is not active; maintenance may proceed.")


def archives(directory: Path) -> tuple[Path, ...]:
    return tuple(
        sorted(
            directory.glob("jellyfin-backup-*.zip"),
            key=lambda path: (path.stat().st_mtime_ns, path.name),
            reverse=True,
        )
    )


def prune_archives(directory: Path, keep: int) -> tuple[Path, ...]:
    if keep < 0:
        raise JellyfinServiceError("Jellyfin backup retention cannot be negative")
    removed = archives(directory)[keep:]
    for path in removed:
        path.unlink()
    return removed


def create_backup_artifact(
    create_backup: Callable[[], Path],
    *,
    source_dir: Path,
    staging_dir: Path,
    keep_staging: int,
    keep_source: int,
) -> BackupResult:
    source = create_backup().resolve()
    source_root = source_dir.resolve()
    if not source.is_relative_to(source_root) or not source.is_file():
        raise JellyfinServiceError("Jellyfin backup API did not return a valid archive path")
    if not source.match("jellyfin-backup-*.zip"):
        raise JellyfinServiceError("Jellyfin backup API returned an unexpected archive name")
    if not staging_dir.is_dir():
        raise JellyfinServiceError(f"Jellyfin backup staging directory is missing: {staging_dir}")

    destination = staging_dir / source.name
    shutil.copyfile(source, destination)
    destination.chmod(0o640)
    return BackupResult(
        destination=destination,
        removed_staging=prune_archives(staging_dir, keep_staging),
        removed_source=prune_archives(source_dir, keep_source),
    )
