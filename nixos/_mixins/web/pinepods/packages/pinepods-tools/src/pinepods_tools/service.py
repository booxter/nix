from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from .api import PinepodsApi, PinepodsApiError
from .database import Database
from .models import CreateAdminRequest


class PinepodsServiceError(RuntimeError):
    pass


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def bootstrap_admin(
    api: PinepodsApi,
    request: CreateAdminRequest,
    *,
    attempts: int,
    interval: float,
    sleep: Callable[[float], None],
) -> int | str | None:
    for attempt in range(attempts):
        try:
            status = api.self_service_status()
        except PinepodsApiError:
            status = None
        if status is not None:
            if status.first_admin_created:
                return None
            return api.create_admin(request).user_id
        if attempt == attempts - 1:
            raise PinepodsServiceError("Timed out waiting for the PinePods setup API")
        sleep(interval)
    raise PinepodsServiceError("PinePods setup attempts must be positive")


def native_backup(
    api: PinepodsApi,
    database: Database,
    *,
    keep: int,
    attempts: int,
    interval: float,
    sleep: Callable[[float], None],
) -> tuple[str, ...]:
    api_key = database.admin_api_key()
    if api_key is None:
        raise PinepodsServiceError("PinePods has no API key for a non-background administrator")
    task_id = api.start_backup(api_key).task_id
    for attempt in range(attempts):
        task = api.task(task_id)
        if task.status == "SUCCESS":
            break
        if task.status == "FAILED":
            raise PinepodsServiceError("PinePods native backup failed")
        if task.status not in ("PENDING", "DOWNLOADING"):
            raise PinepodsServiceError(
                f"PinePods returned an unknown backup task state: {task.status}"
            )
        if attempt == attempts - 1:
            raise PinepodsServiceError("PinePods native backup timed out")
        sleep(interval)
    else:
        raise PinepodsServiceError("PinePods backup attempts must be positive")

    old_backups = tuple(file.filename for file in api.backup_files(api_key).backup_files[keep:])
    for filename in old_backups:
        api.delete_backup(api_key, filename)
    return old_backups
