from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from .api import JellystatApi, JellystatApiError
from .models import JellyfinConfiguration, UserCredentials


class JellystatServiceError(RuntimeError):
    pass


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def wait_for_state(
    api: JellystatApi,
    *,
    configured: bool,
    attempts: int,
    interval: float,
    sleep: Callable[[float], None],
) -> int:
    for attempt in range(attempts):
        try:
            state = api.configuration_state()
        except JellystatApiError:
            state = None
        if state is not None and (not configured or state == 2):
            return state
        if attempt == attempts - 1:
            expectation = "configured Jellystat" if configured else "Jellystat setup API"
            raise JellystatServiceError(f"Timed out waiting for {expectation}")
        sleep(interval)
    raise JellystatServiceError("Jellystat setup attempts must be positive")


def reconcile_configuration(
    api: JellystatApi,
    configuration: JellyfinConfiguration,
    *,
    attempts: int,
    interval: float,
    sleep: Callable[[float], None],
) -> bool:
    state = wait_for_state(
        api,
        configured=False,
        attempts=attempts,
        interval=interval,
        sleep=sleep,
    )
    token: str | None = None
    if state < 2:
        token = api.create_user(UserCredentials(username="oauth2-proxy", password="disabled"))
        api.configure(configuration)

    if token is None:
        try:
            token = api.login()
        except JellystatApiError:
            token = None
    if token is None:
        return False

    # Jellystat's setconfig endpoint calls Jellyfin synchronously, so unit
    # ordering cannot establish readiness for this operation.
    for attempt in range(attempts):
        try:
            api.set_configuration(token, configuration)
            break
        except JellystatApiError:
            if attempt == attempts - 1:
                raise JellystatServiceError("Timed out waiting for Jellyfin setup API")
            sleep(interval)
    else:
        raise JellystatServiceError("Jellystat setup attempts must be positive")

    api.disable_login_requirement(token)
    if api.library_count(token) == 0:
        api.begin_sync(token)
    return True


def create_backup(
    api: JellystatApi,
    backup_dir: Path,
    *,
    attempts: int,
    interval: float,
    sleep: Callable[[float], None],
) -> Path:
    wait_for_state(
        api,
        configured=True,
        attempts=attempts,
        interval=interval,
        sleep=sleep,
    )
    token = api.login()
    if token is None:
        raise JellystatServiceError("Jellystat login did not return a backup token")

    before = {path: path.stat().st_mtime_ns for path in backup_dir.glob("backup_*.json")}
    api.begin_backup(token)
    created = sorted(
        (
            path
            for path in backup_dir.glob("backup_*.json")
            if path.stat().st_mtime_ns > before.get(path, -1)
        ),
        key=lambda path: path.stat().st_mtime_ns,
        reverse=True,
    )
    if not created:
        raise JellystatServiceError(
            f"Jellystat backup endpoint did not create a new backup file in {backup_dir}"
        )
    return created[0]
