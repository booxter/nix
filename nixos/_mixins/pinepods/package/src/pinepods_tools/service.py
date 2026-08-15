from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from .api import PinepodsApi, PinepodsApiError
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
