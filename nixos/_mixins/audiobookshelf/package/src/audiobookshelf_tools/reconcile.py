from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from .api import ApiNotReady, AudiobookshelfApi, AudiobookshelfError
from .models import CurrentLibrary, CurrentSettings, DesiredLibrary, OidcSettings, ReconcileSettings
from .systemd import UnitRestarter


class ReadinessTimeout(AudiobookshelfError):
    def __init__(self, status_code: int | None) -> None:
        status = str(status_code) if status_code is not None else "unreachable"
        super().__init__(f"Audiobookshelf API did not become ready; last HTTP status: {status}")


class LibraryConflict(AudiobookshelfError):
    pass


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def read_settings(path: Path) -> ReconcileSettings:
    return ReconcileSettings.model_validate_json(path.read_text(encoding="utf-8"))


def wait_for_auth_settings(
    api: AudiobookshelfApi,
    *,
    timeout: float,
    interval: float,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> CurrentSettings:
    deadline = clock() + timeout
    last_status: int | None = None
    while True:
        try:
            return api.auth_settings()
        except ApiNotReady as error:
            last_status = error.status_code
        if clock() >= deadline:
            raise ReadinessTimeout(last_status)
        sleep(interval)


def reconcile_oidc(
    api: AudiobookshelfApi,
    settings: OidcSettings,
    client_secret: str,
    restarter: UnitRestarter,
    restart_unit: str,
    *,
    timeout: float,
    interval: float,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> bool:
    desired_payload = settings.with_client_secret(client_secret).model_dump(
        mode="json", by_alias=True
    )
    current = wait_for_auth_settings(
        api, timeout=timeout, interval=interval, clock=clock, sleep=sleep
    )
    if all(current.root.get(key) == value for key, value in desired_payload.items()):
        return False
    api.update_auth_settings(desired_payload)
    restarter.try_restart(restart_unit)
    wait_for_auth_settings(api, timeout=timeout, interval=interval, clock=clock, sleep=sleep)
    return True


def reconcile_backups(api: AudiobookshelfApi, settings: ReconcileSettings) -> bool:
    if settings.backups is None:
        return False
    desired = settings.backups.model_dump(mode="json", by_alias=True)
    current = api.settings()
    if all(current.root.get(key) == value for key, value in desired.items()):
        return False
    api.update_settings(desired)
    return True


def find_library(
    desired: DesiredLibrary, current: tuple[CurrentLibrary, ...]
) -> CurrentLibrary | None:
    path_matches = [
        library
        for library in current
        if any(folder.full_path == desired.path for folder in library.folders)
    ]
    if len(path_matches) > 1:
        raise LibraryConflict(f"multiple Audiobookshelf libraries use {desired.path}")
    if path_matches:
        return path_matches[0]
    if any(library.name == desired.name for library in current):
        raise LibraryConflict(
            f"Audiobookshelf library name {desired.name!r} already uses a different path"
        )
    return None


def reconcile_libraries(api: AudiobookshelfApi, desired: tuple[DesiredLibrary, ...]) -> int:
    paths = [library.path for library in desired]
    names = [library.name for library in desired]
    if len(paths) != len(set(paths)):
        raise LibraryConflict("desired Audiobookshelf library paths must be unique")
    if len(names) != len(set(names)):
        raise LibraryConflict("desired Audiobookshelf library names must be unique")
    current = api.libraries().libraries
    changed = 0
    for library in desired:
        existing = find_library(library, current)
        if existing is None:
            api.create_library(library.creation_payload())
            changed += 1
            continue
        if existing.media_type != library.media_type:
            raise LibraryConflict(
                f"Audiobookshelf library at {library.path} has media type {existing.media_type!r}"
            )
        safe_payload = library.safe_update_payload()
        current_values: dict[str, object] = {
            "name": existing.name,
            "provider": existing.provider,
            "icon": existing.icon,
            "settings": {"audiobooksOnly": existing.settings.audiobooks_only},
        }
        if any(current_values[key] != value for key, value in safe_payload.items()):
            api.update_library(existing.id, safe_payload)
            changed += 1
    return changed


def reconcile(
    api: AudiobookshelfApi,
    settings: ReconcileSettings,
    client_secret: str,
    restarter: UnitRestarter,
    restart_unit: str,
    *,
    timeout: float,
    interval: float,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> tuple[bool, bool, int]:
    oidc_changed = reconcile_oidc(
        api,
        settings.oidc,
        client_secret,
        restarter,
        restart_unit,
        timeout=timeout,
        interval=interval,
        clock=clock,
        sleep=sleep,
    )
    backups_changed = reconcile_backups(api, settings)
    libraries_changed = reconcile_libraries(api, settings.libraries)
    return oidc_changed, backups_changed, libraries_changed
