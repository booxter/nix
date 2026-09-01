from __future__ import annotations

import json
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from enum import StrEnum
from types import TracebackType
from typing import Protocol, Self, cast
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

JsonObject = dict[str, object]


class HermesError(Exception):
    """A request to Hermes failed."""


class HermesHttpError(HermesError):
    def __init__(self, status: int, detail: str) -> None:
        self.status = status
        super().__init__(f"Hermes returned HTTP {status}: {detail}")


class RunState(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    WAITING_FOR_APPROVAL = "waiting_for_approval"
    STOPPING = "stopping"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

    @property
    def terminal(self) -> bool:
        return self in {RunState.COMPLETED, RunState.FAILED, RunState.CANCELLED}


@dataclass(frozen=True)
class RunStatus:
    run_id: str
    state: RunState
    created_at: float | None
    updated_at: float | None
    model: str
    last_event: str
    output: str
    error: str
    usage: JsonObject
    raw: JsonObject


@dataclass(frozen=True)
class StopResult:
    run_id: str
    state: RunState
    raw: JsonObject


@dataclass(frozen=True)
class RunSummary:
    run_id: str
    status: str
    last_active: float | None
    model: str
    preview: str


class Client(Protocol):
    def start_run(self, instruction: str) -> str: ...

    def list_runs(self, limit: int) -> list[RunSummary]: ...

    def watch_run(self, run_id: str) -> Iterator[JsonObject]: ...

    def get_run(self, run_id: str) -> RunStatus: ...

    def approve_run(self, run_id: str, choice: str, resolve_all: bool) -> JsonObject: ...

    def stop_run(self, run_id: str) -> StopResult: ...


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
    def __call__(self, request: Request, timeout: float) -> HttpResponse: ...


class HermesClient:
    def __init__(
        self,
        api_url: str,
        api_key: str,
        *,
        timeout_seconds: float = 20.0,
        opener: Opener | None = None,
    ) -> None:
        self._api_url = api_url.rstrip("/")
        self._api_key = api_key
        self._timeout_seconds = timeout_seconds
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

    def _request_json(self, method: str, path: str, body: JsonObject | None = None) -> JsonObject:
        request = self._request(method, path, body)
        try:
            with self._opener(request, self._timeout_seconds) as response:
                parsed = json.load(response)
        except HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise HermesHttpError(error.code, detail) from error
        except URLError as error:
            raise HermesError(f"Unable to contact Hermes: {error.reason}") from error
        if not isinstance(parsed, dict):
            raise HermesError("Hermes returned a non-object JSON response")
        return cast(JsonObject, parsed)

    def start_run(self, instruction: str) -> str:
        response = self._request_json("POST", "/v1/runs", {"input": instruction})
        run_id = response.get("run_id")
        if not isinstance(run_id, str):
            raise HermesError("Hermes did not return a run_id")
        return run_id

    def watch_run(self, run_id: str) -> Iterator[JsonObject]:
        request = self._request("GET", f"/v1/runs/{run_id}/events")
        try:
            with self._opener(request, self._timeout_seconds) as response:
                yield from parse_sse(response)
        except HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise HermesHttpError(error.code, detail) from error
        except URLError as error:
            raise HermesError(f"Unable to contact Hermes: {error.reason}") from error

    def list_runs(self, limit: int) -> list[RunSummary]:
        query = urlencode({"limit": limit, "offset": 0, "source": "api_server"})
        response = self._request_json("GET", f"/api/sessions?{query}")
        sessions = response.get("data")
        if not isinstance(sessions, list):
            raise HermesError("Hermes did not return a session list")

        summaries: list[RunSummary] = []
        for value in sessions:
            if not isinstance(value, dict):
                continue
            run_id = value.get("id")
            if not isinstance(run_id, str) or not run_id.startswith("run_"):
                continue
            status = "expired"
            try:
                run = self.get_run(run_id)
                status = run.state.value
            except HermesHttpError as error:
                if error.status != 404:
                    raise
            last_active = value.get("last_active")
            summaries.append(
                RunSummary(
                    run_id=run_id,
                    status=status,
                    last_active=float(last_active)
                    if isinstance(last_active, int | float)
                    else None,
                    model=str(value.get("model") or ""),
                    preview=str(value.get("preview") or ""),
                )
            )
        return summaries

    def get_run(self, run_id: str) -> RunStatus:
        return parse_run_status(self._request_json("GET", f"/v1/runs/{run_id}"))

    def approve_run(self, run_id: str, choice: str, resolve_all: bool) -> JsonObject:
        body: JsonObject = {"choice": choice}
        if resolve_all:
            body["all"] = True
        return self._request_json("POST", f"/v1/runs/{run_id}/approval", body)

    def stop_run(self, run_id: str) -> StopResult:
        return parse_stop_result(self._request_json("POST", f"/v1/runs/{run_id}/stop"))


def _optional_float(value: object, field: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, int | float):
        return float(value)
    raise HermesError(f"Hermes returned an invalid {field}")


def _required_string(value: object, field: str) -> str:
    if isinstance(value, str) and value:
        return value
    raise HermesError(f"Hermes did not return a valid {field}")


def _run_state(value: object) -> RunState:
    try:
        return RunState(_required_string(value, "status"))
    except ValueError as error:
        raise HermesError(f"Hermes returned an unknown run status: {value}") from error


def parse_run_status(payload: JsonObject) -> RunStatus:
    usage_value = payload.get("usage")
    usage = cast(JsonObject, usage_value) if isinstance(usage_value, dict) else {}
    return RunStatus(
        run_id=_required_string(payload.get("run_id"), "run_id"),
        state=_run_state(payload.get("status")),
        created_at=_optional_float(payload.get("created_at"), "created_at"),
        updated_at=_optional_float(payload.get("updated_at"), "updated_at"),
        model=str(payload.get("model") or ""),
        last_event=str(payload.get("last_event") or ""),
        output=str(payload.get("output") or ""),
        error=str(payload.get("error") or ""),
        usage=usage,
        raw=payload,
    )


def parse_stop_result(payload: JsonObject) -> StopResult:
    return StopResult(
        run_id=_required_string(payload.get("run_id"), "run_id"),
        state=_run_state(payload.get("status")),
        raw=payload,
    )


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
