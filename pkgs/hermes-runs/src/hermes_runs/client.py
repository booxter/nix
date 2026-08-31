from __future__ import annotations

import json
from collections.abc import Iterable, Iterator
from types import TracebackType
from typing import Protocol, Self, cast
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

JsonObject = dict[str, object]


class HermesError(Exception):
    """A request to Hermes failed."""


class HermesHttpError(HermesError):
    def __init__(self, status: int, detail: str) -> None:
        self.status = status
        super().__init__(f"Hermes returned HTTP {status}: {detail}")


class Client(Protocol):
    def request(self, method: str, path: str, body: JsonObject | None = None) -> JsonObject: ...

    def events(self, run_id: str) -> Iterator[JsonObject]: ...


class HttpResponse(Protocol):
    def __enter__(self) -> Self: ...

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None: ...

    def __iter__(self) -> Iterator[bytes]: ...

    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def __call__(self, request: Request) -> HttpResponse: ...


class HermesClient:
    def __init__(self, api_url: str, api_key: str, opener: Opener | None = None) -> None:
        self._api_url = api_url.rstrip("/")
        self._api_key = api_key
        self._opener = opener or cast(Opener, urlopen)

    def _request(self, method: str, path: str, body: JsonObject | None = None) -> Request:
        data = json.dumps(body).encode() if body is not None else None
        return Request(
            f"{self._api_url}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self._api_key}",
                "Content-Type": "application/json",
            },
        )

    def request(self, method: str, path: str, body: JsonObject | None = None) -> JsonObject:
        request = self._request(method, path, body)
        try:
            with self._opener(request) as response:
                parsed = json.load(response)
        except HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise HermesHttpError(error.code, detail) from error
        except URLError as error:
            raise HermesError(f"Unable to contact Hermes: {error.reason}") from error
        if not isinstance(parsed, dict):
            raise HermesError("Hermes returned a non-object JSON response")
        return cast(JsonObject, parsed)

    def events(self, run_id: str) -> Iterator[JsonObject]:
        request = self._request("GET", f"/v1/runs/{run_id}/events")
        try:
            with self._opener(request) as response:
                yield from parse_sse(response)
        except HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise HermesHttpError(error.code, detail) from error
        except URLError as error:
            raise HermesError(f"Unable to contact Hermes: {error.reason}") from error


def parse_sse(lines: Iterable[bytes]) -> Iterator[JsonObject]:
    data: list[str] = []
    for raw_line in lines:
        line = raw_line.decode(errors="replace").rstrip("\r\n")
        if line == "":
            if data:
                yield _parse_event("\n".join(data))
                data = []
        elif line.startswith("data:"):
            data.append(line.removeprefix("data:").lstrip())
    if data:
        yield _parse_event("\n".join(data))


def _parse_event(data: str) -> JsonObject:
    try:
        parsed = json.loads(data)
    except json.JSONDecodeError as error:
        raise HermesError(f"Hermes returned invalid event JSON: {data}") from error
    if not isinstance(parsed, dict):
        raise HermesError(f"Hermes returned a non-object event: {data}")
    return cast(JsonObject, parsed)
