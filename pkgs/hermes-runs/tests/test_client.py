from __future__ import annotations

from io import BytesIO
from types import TracebackType
from urllib.error import HTTPError, URLError
from urllib.request import Request

import pytest

from hermes_runs.client import (
    HermesClient,
    HermesError,
    HttpResponse,
    RunState,
    RunSummary,
    parse_run_status,
    parse_sse,
)


class FakeResponse(BytesIO):
    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()


class FakeOpener:
    def __init__(self, response: bytes | Exception | list[bytes | Exception]) -> None:
        self.responses = response if isinstance(response, list) else [response]
        self.requests: list[Request] = []
        self.timeouts: list[float] = []

    def __call__(self, request: Request, timeout: float) -> HttpResponse:
        self.requests.append(request)
        self.timeouts.append(timeout)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return FakeResponse(response)


def test_parse_sse_ignores_comments_and_combines_data_lines() -> None:
    lines = iter(
        [
            b": keepalive\n",
            b'data: {"event":\n',
            b'data: "run.completed"}\n',
            b"\n",
            b": stream closed\n",
        ]
    )

    assert list(parse_sse(lines)) == [{"event": "run.completed"}]


def test_parse_sse_emits_unterminated_final_event() -> None:
    assert list(parse_sse(iter([b'data: {"event": "run.failed"}\n']))) == [{"event": "run.failed"}]


@pytest.mark.parametrize("data", [b"data: nope\n\n", b"data: []\n\n"])
def test_parse_sse_rejects_invalid_events(data: bytes) -> None:
    with pytest.raises(HermesError):
        list(parse_sse(iter(data.splitlines(keepends=True))))


def test_start_run_sends_auth_and_json() -> None:
    opener = FakeOpener(b'{"run_id": "run_123"}')
    client = HermesClient("http://localhost:8642/", "secret", timeout_seconds=7.5, opener=opener)

    assert client.start_run("hello") == "run_123"
    request = opener.requests[0]
    assert request.full_url == "http://localhost:8642/v1/runs"
    assert request.get_header("Authorization") == "Bearer secret"
    assert request.data == b'{"input": "hello"}'
    assert opener.timeouts == [7.5]


def test_start_run_requires_run_id() -> None:
    client = HermesClient("http://localhost:8642", "secret", opener=FakeOpener(b"{}"))

    with pytest.raises(HermesError, match="run_id"):
        client.start_run("hello")


def test_request_rejects_non_object_response() -> None:
    client = HermesClient("http://localhost:8642", "secret", opener=FakeOpener(b"[]"))

    with pytest.raises(HermesError, match="non-object"):
        client.get_run("run_123")


def test_events_parse_stream() -> None:
    client = HermesClient(
        "http://localhost:8642",
        "secret",
        opener=FakeOpener(b'data: {"event": "run.completed"}\n\n'),
    )

    assert list(client.watch_run("run_123")) == [{"event": "run.completed"}]


def test_run_operations_map_to_api_endpoints() -> None:
    opener = FakeOpener(
        [
            b'{"run_id": "run_123", "status": "running"}',
            b'{"status": "ok"}',
            b'{"status": "ok"}',
            b'{"run_id": "run_123", "status": "stopping"}',
        ]
    )
    client = HermesClient("http://localhost:8642", "secret", opener=opener)

    client.get_run("run_123")
    client.approve_run("run_123", "once", False)
    client.approve_run("run_123", "deny", True)
    client.stop_run("run_123")

    assert [(request.method, request.full_url, request.data) for request in opener.requests] == [
        ("GET", "http://localhost:8642/v1/runs/run_123", None),
        (
            "POST",
            "http://localhost:8642/v1/runs/run_123/approval",
            b'{"choice": "once"}',
        ),
        (
            "POST",
            "http://localhost:8642/v1/runs/run_123/approval",
            b'{"choice": "deny", "all": true}',
        ),
        ("POST", "http://localhost:8642/v1/runs/run_123/stop", None),
    ]


def test_list_runs_merges_status_and_filters_non_run_sessions() -> None:
    sessions = b"""{
      "data": [
        {"id": "run_123", "last_active": 12.5, "model": "qwen", "preview": "inspect"},
        {"id": "api-chat", "last_active": 10, "model": "qwen", "preview": "chat"}
      ]
    }"""
    opener = FakeOpener([sessions, b'{"run_id": "run_123", "status": "running"}'])
    client = HermesClient("http://localhost:8642", "secret", opener=opener)

    assert client.list_runs(5) == [
        RunSummary(
            run_id="run_123",
            status="running",
            last_active=12.5,
            model="qwen",
            preview="inspect",
        )
    ]
    assert opener.requests[0].full_url == (
        "http://localhost:8642/api/sessions?limit=5&offset=0&source=api_server"
    )


def test_list_runs_marks_expired_status() -> None:
    sessions = b'{"data": [{"id": "run_123"}]}'
    missing = HTTPError("http://localhost", 404, "Not Found", {}, BytesIO(b"missing"))
    client = HermesClient("http://localhost:8642", "secret", opener=FakeOpener([sessions, missing]))

    assert client.list_runs(20)[0].status == "expired"


def test_list_runs_requires_session_list() -> None:
    client = HermesClient("http://localhost:8642", "secret", opener=FakeOpener(b"{}"))

    with pytest.raises(HermesError, match="session list"):
        client.list_runs(20)


@pytest.mark.parametrize("events", [False, True])
def test_http_error_includes_response(events: bool) -> None:
    error = HTTPError(
        "http://localhost:8642",
        401,
        "Unauthorized",
        {},
        BytesIO(b'{"error": "unauthorized"}'),
    )
    client = HermesClient("http://localhost:8642", "secret", opener=FakeOpener(error))

    with pytest.raises(HermesError, match='HTTP 401.*"unauthorized"'):
        if events:
            list(client.watch_run("run_123"))
        else:
            client.get_run("run_123")


@pytest.mark.parametrize("events", [False, True])
def test_connection_error(events: bool) -> None:
    client = HermesClient(
        "http://localhost:8642",
        "secret",
        opener=FakeOpener(URLError("connection refused")),
    )

    with pytest.raises(HermesError, match="connection refused"):
        if events:
            list(client.watch_run("run_123"))
        else:
            client.get_run("run_123")


def test_parse_run_status_returns_typed_fields() -> None:
    status = parse_run_status(
        {
            "run_id": "run_123",
            "status": "completed",
            "created_at": 10,
            "updated_at": 12.5,
            "model": "radarr-repair",
            "last_event": "run.completed",
            "output": "done",
            "usage": {"total_tokens": 42},
        }
    )

    assert status.run_id == "run_123"
    assert status.state is RunState.COMPLETED
    assert status.state.terminal
    assert status.created_at == 10.0
    assert status.updated_at == 12.5
    assert status.usage == {"total_tokens": 42}


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({"status": "running"}, "run_id"),
        ({"run_id": "run_123", "status": "future"}, "unknown run status"),
        ({"run_id": "run_123", "status": "running", "updated_at": "now"}, "updated_at"),
    ],
)
def test_parse_run_status_rejects_invalid_payload(payload: dict[str, object], message: str) -> None:
    with pytest.raises(HermesError, match=message):
        parse_run_status(payload)
