from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from .api import ApiNotReady, AudiobookshelfApi, AudiobookshelfError, UpdateFailed
from .models import BackupSettings, CurrentSettings, OidcSettings
from .systemd import UnitRestarter

RETRYABLE_HTTP_STATUSES = frozenset((408, 429, 500, 502, 503, 504))


class ReadinessTimeout(AudiobookshelfError):
    def __init__(self, status_code: int | None) -> None:
        status = str(status_code) if status_code is not None else "unreachable"
        super().__init__(f"Audiobookshelf API did not become ready; last HTTP status: {status}")


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def read_oidc_settings(path: Path) -> OidcSettings:
    return OidcSettings.model_validate_json(path.read_text(encoding="utf-8"))


def read_backup_settings(path: Path) -> BackupSettings:
    return BackupSettings.model_validate_json(path.read_text(encoding="utf-8"))


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
    desired = settings.with_client_secret(client_secret)
    desired_payload = desired.model_dump(mode="json", by_alias=True)
    current = wait_for_auth_settings(
        api,
        timeout=timeout,
        interval=interval,
        clock=clock,
        sleep=sleep,
    )
    if all(current.root.get(key) == value for key, value in desired_payload.items()):
        return False
    api.update_auth_settings(desired_payload)
    restarter.try_restart(restart_unit)
    return True


def configure_backups(
    api: AudiobookshelfApi,
    settings: BackupSettings,
    *,
    retry_count: int,
    retry_delay: float,
    sleep: Callable[[float], None],
) -> None:
    payload = settings.model_dump(mode="json", by_alias=True)
    for attempt in range(retry_count + 1):
        try:
            api.update_backup_settings(payload)
            return
        except UpdateFailed as error:
            retryable = error.status_code is None or error.status_code in RETRYABLE_HTTP_STATUSES
            if not retryable or attempt == retry_count:
                raise
            sleep(retry_delay)
