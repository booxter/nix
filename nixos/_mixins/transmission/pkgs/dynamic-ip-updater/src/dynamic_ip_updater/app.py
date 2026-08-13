from __future__ import annotations

import urllib.request
from dataclasses import dataclass
from http.cookiejar import MozillaCookieJar
from pathlib import Path

from atomic_file_writes import atomic_path
from pydantic import BaseModel, ConfigDict, Field, ValidationError

MAX_RESPONSE_BYTES = 1024 * 1024


class DynamicIPResponse(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True)

    success: bool = Field(alias="Success")


class RejectedResponse(Exception):
    def __init__(self, body: bytes) -> None:
        super().__init__("dynamic IP update was rejected")
        self.body = body


@dataclass(frozen=True)
class DynamicIPClient:
    url: str
    timeout_seconds: float

    def update(self, cookie_jar: MozillaCookieJar) -> bytes:
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
        request = urllib.request.Request(
            self.url,
            headers={"User-Agent": "dynamic-ip-updater/0.1"},
        )
        with opener.open(request, timeout=self.timeout_seconds) as response:
            body = bytes(response.read(MAX_RESPONSE_BYTES + 1))
        if len(body) > MAX_RESPONSE_BYTES:
            raise ValueError("dynamic IP response exceeds one MiB")
        return body


def load_cookie_jar(path: Path) -> MozillaCookieJar:
    try:
        if path.stat().st_size == 0:
            raise ValueError(f"cookie jar is empty: {path}")
    except FileNotFoundError as error:
        raise ValueError(f"cookie jar does not exist: {path}") from error

    cookie_jar = MozillaCookieJar(str(path))
    try:
        cookie_jar.load(ignore_discard=True, ignore_expires=True)
    except OSError as error:
        raise ValueError(f"failed to load cookie jar {path}: {error}") from error
    if not tuple(cookie_jar):
        raise ValueError(f"cookie jar contains no cookies: {path}")
    return cookie_jar


def save_cookie_jar(cookie_jar: MozillaCookieJar, path: Path) -> None:
    with atomic_path(path, mode=0o600) as temporary:
        cookie_jar.save(
            str(temporary),
            ignore_discard=True,
            ignore_expires=True,
        )


def update(cookie_path: Path, client: DynamicIPClient) -> bytes:
    cookie_jar = load_cookie_jar(cookie_path)
    body = client.update(cookie_jar)
    try:
        response = DynamicIPResponse.model_validate_json(body)
    except ValidationError as error:
        raise ValueError("dynamic IP endpoint returned an invalid response") from error
    if not response.success:
        raise RejectedResponse(body)
    save_cookie_jar(cookie_jar, cookie_path)
    return body
