from __future__ import annotations

from io import BytesIO
from types import TracebackType
from urllib.error import HTTPError, URLError
from urllib.request import Request

import pytest

from hermes_runs.client import HermesClient, HermesError, HttpResponse, parse_sse


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
    def __init__(self, response: bytes | Exception) -> None:
        self.response = response
        self.requests: list[Request] = []

    def __call__(self, request: Request) -> HttpResponse:
        self.requests.append(request)
        if isinstance(self.response, Exception):
            raise self.response
        return FakeResponse(self.response)


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


def test_request_sends_auth_and_json() -> None:
    opener = FakeOpener(b'{"run_id": "run_123"}')
    client = HermesClient("http://localhost:8642/", "secret", opener)

    assert client.request("POST", "/v1/runs", {"input": "hello"}) == {"run_id": "run_123"}
    request = opener.requests[0]
    assert request.full_url == "http://localhost:8642/v1/runs"
    assert request.get_header("Authorization") == "Bearer secret"
    assert request.data == b'{"input": "hello"}'


def test_request_rejects_non_object_response() -> None:
    client = HermesClient("http://localhost:8642", "secret", FakeOpener(b"[]"))

    with pytest.raises(HermesError, match="non-object"):
        client.request("GET", "/v1/runs/run_123")


def test_events_parse_stream() -> None:
    client = HermesClient(
        "http://localhost:8642",
        "secret",
        FakeOpener(b'data: {"event": "run.completed"}\n\n'),
    )

    assert list(client.events("run_123")) == [{"event": "run.completed"}]


@pytest.mark.parametrize("events", [False, True])
def test_http_error_includes_response(events: bool) -> None:
    error = HTTPError(
        "http://localhost:8642",
        401,
        "Unauthorized",
        {},
        BytesIO(b'{"error": "unauthorized"}'),
    )
    client = HermesClient("http://localhost:8642", "secret", FakeOpener(error))

    with pytest.raises(HermesError, match='HTTP 401.*"unauthorized"'):
        if events:
            list(client.events("run_123"))
        else:
            client.request("GET", "/v1/runs/run_123")


@pytest.mark.parametrize("events", [False, True])
def test_connection_error(events: bool) -> None:
    client = HermesClient(
        "http://localhost:8642", "secret", FakeOpener(URLError("connection refused"))
    )

    with pytest.raises(HermesError, match="connection refused"):
        if events:
            list(client.events("run_123"))
        else:
            client.request("GET", "/v1/runs/run_123")
