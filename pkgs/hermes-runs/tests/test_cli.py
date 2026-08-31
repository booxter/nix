from __future__ import annotations

from collections.abc import Iterator
from io import StringIO

import pytest

from hermes_runs.cli import run
from hermes_runs.client import HermesError, JsonObject


class FakeClient:
    def __init__(self, response: JsonObject | None = None) -> None:
        self.response = response or {"status": "ok"}
        self.requests: list[tuple[str, str, JsonObject | None]] = []
        self.event_values: list[JsonObject] = []

    def request(self, method: str, path: str, body: JsonObject | None = None) -> JsonObject:
        self.requests.append((method, path, body))
        return self.response

    def events(self, run_id: str) -> Iterator[JsonObject]:
        self.requests.append(("GET", f"/v1/runs/{run_id}/events", None))
        yield from self.event_values


def invoke(arguments: list[str], client: FakeClient) -> str:
    output = StringIO()
    assert run(arguments, {}, output, client) == 0
    return output.getvalue()


def test_run_prints_run_id() -> None:
    client = FakeClient({"run_id": "run_123", "status": "started"})

    assert invoke(["run", "inspect files"], client) == "run_123\n"
    assert client.requests == [("POST", "/v1/runs", {"input": "inspect files"})]


def test_run_requires_run_id() -> None:
    with pytest.raises(HermesError, match="run_id"):
        invoke(["run", "inspect files"], FakeClient())


def test_status_prints_json() -> None:
    client = FakeClient({"run_id": "run_123", "status": "running"})

    assert '"status": "running"' in invoke(["status", "run_123"], client)
    assert client.requests == [("GET", "/v1/runs/run_123", None)]


@pytest.mark.parametrize("resolve_all", [False, True])
def test_approve(resolve_all: bool) -> None:
    client = FakeClient()
    arguments = ["approve", "run_123", "once"]
    if resolve_all:
        arguments.append("--all")

    invoke(arguments, client)

    expected: JsonObject = {"choice": "once"}
    if resolve_all:
        expected["all"] = True
    assert client.requests == [("POST", "/v1/runs/run_123/approval", expected)]


def test_stop() -> None:
    client = FakeClient()

    invoke(["stop", "run_123"], client)

    assert client.requests == [("POST", "/v1/runs/run_123/stop", None)]


def test_watch_renders_text_and_events() -> None:
    client = FakeClient()
    client.event_values = [
        {"event": "message.delta", "delta": "hello "},
        {"event": "message.delta", "delta": "world"},
        {"event": "tool.started", "tool": "terminal", "preview": "ls"},
        {"event": "run.completed", "output": "hello world", "usage": {"total_tokens": 4}},
    ]

    assert invoke(["watch", "run_123"], client) == (
        'hello world\n[tool.started] {"preview": "ls", "tool": "terminal"}\n'
        '[run.completed] {"usage": {"total_tokens": 4}}\n'
    )


def test_watch_adds_newline_after_final_delta() -> None:
    client = FakeClient()
    client.event_values = [{"event": "message.delta", "delta": "done"}]

    assert invoke(["watch", "run_123"], client) == "done\n"


def test_watch_uses_completed_output_when_no_deltas_arrived() -> None:
    client = FakeClient()
    client.event_values = [{"event": "run.completed", "output": "final answer"}]

    assert invoke(["watch", "run_123"], client) == "final answer\n[run.completed]\n"


def test_environment_requires_api_key() -> None:
    with pytest.raises(HermesError, match="HERMES_API_KEY"):
        run(["status", "run_123"], {}, StringIO())
