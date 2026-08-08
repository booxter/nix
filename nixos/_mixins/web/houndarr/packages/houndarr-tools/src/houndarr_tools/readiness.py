from __future__ import annotations

from collections.abc import Callable, Sequence

import httpx


class ReadinessTimeout(RuntimeError):
    def __init__(self, urls: Sequence[str]) -> None:
        super().__init__(f"Timed out waiting for Houndarr Arr backends: {' '.join(urls)}")


def _ready(client: httpx.Client, url: str) -> bool:
    try:
        response = client.get(url)
        response.raise_for_status()
    except httpx.HTTPError:
        return False
    return True


def wait_for_backends(
    client: httpx.Client,
    urls: Sequence[str],
    *,
    timeout: float,
    interval: float,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> None:
    deadline = clock() + timeout
    while clock() < deadline:
        readiness = [_ready(client, url) for url in urls]
        if all(readiness):
            return
        sleep(interval)
    raise ReadinessTimeout(urls)
