from __future__ import annotations

from collections.abc import Iterator
from io import StringIO

import pytest

from hermes_runs.cli import run
from hermes_runs.client import HermesError, HermesHttpError, JsonObject


class FakeClient:
    def __init__(self, response: JsonObject | None = None, run_id: str = "run_123") -> None:
        self.response = response if response is not None else {"status": "ok"}
        self.run_id = run_id
        self.calls: list[tuple[object, ...]] = []
        self.event_values: list[JsonObject] = []

    def start_run(self, instruction: str) -> str:
        self.calls.append(("start_run", instruction))
        return self.run_id

    def watch_run(self, run_id: str) -> Iterator[JsonObject]:
        self.calls.append(("watch_run", run_id))
        yield from self.event_values

    def get_run(self, run_id: str) -> JsonObject:
        self.calls.append(("get_run", run_id))
        return self.response

    def approve_run(self, run_id: str, choice: str, resolve_all: bool) -> JsonObject:
        self.calls.append(("approve_run", run_id, choice, resolve_all))
        return self.response

    def stop_run(self, run_id: str) -> JsonObject:
        self.calls.append(("stop_run", run_id))
        return self.response


def invoke(arguments: list[str], client: FakeClient) -> str:
    output = StringIO()
    assert run(arguments, {}, output, client) == 0
    return output.getvalue()


def test_run_prints_run_id() -> None:
    client = FakeClient()

    assert invoke(["run", "inspect files"], client) == "run_123\n"
    assert client.calls == [("start_run", "inspect files")]


def test_status_prints_json() -> None:
    client = FakeClient({"run_id": "run_123", "status": "running"})

    assert invoke(["status", "run_123", "--json"], client) == (
        '{\n  "run_id": "run_123",\n  "status": "running"\n}\n'
    )
    assert client.calls == [("get_run", "run_123")]


def test_status_prints_human_readable_output() -> None:
    client = FakeClient(
        {
            "run_id": "run_123",
            "status": "completed",
            "model": "radarr-repair",
            "last_event": "run.completed",
            "output": "first line\nsecond line — readable",
            "usage": {"total_tokens": 42},
        }
    )

    assert invoke(["status", "run_123"], client) == (
        "run_123: completed (radarr-repair)\n"
        "last event: run.completed\n\n"
        "first line\nsecond line — readable\n\n"
        'usage: {"total_tokens": 42}\n'
    )


@pytest.mark.parametrize("resolve_all", [False, True])
def test_approve(resolve_all: bool) -> None:
    client = FakeClient()
    arguments = ["approve", "run_123", "once"]
    if resolve_all:
        arguments.append("--all")

    invoke(arguments, client)

    assert client.calls == [("approve_run", "run_123", "once", resolve_all)]


def test_stop() -> None:
    client = FakeClient()

    invoke(["stop", "run_123"], client)

    assert client.calls == [("stop_run", "run_123")]


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


class ExpiredEventsClient(FakeClient):
    def watch_run(self, run_id: str) -> Iterator[JsonObject]:
        if False:
            yield {}
        raise HermesHttpError(404, "run not found")


def test_watch_falls_back_to_retained_status() -> None:
    client = ExpiredEventsClient(
        {"run_id": "run_123", "status": "completed", "output": "final answer"}
    )

    assert invoke(["watch", "run_123"], client) == (
        "event stream is no longer available; showing retained status\n\n"
        "run_123: completed\n\nfinal answer\n"
    )
    assert client.calls == [("get_run", "run_123")]


def test_watch_preserves_other_http_errors() -> None:
    class BrokenEventsClient(FakeClient):
        def watch_run(self, run_id: str) -> Iterator[JsonObject]:
            if False:
                yield {}
            raise HermesHttpError(500, "broken")

    with pytest.raises(HermesHttpError, match="HTTP 500"):
        invoke(["watch", "run_123"], BrokenEventsClient())


def test_environment_requires_api_key() -> None:
    with pytest.raises(HermesError, match="HERMES_API_KEY"):
        run(["status", "run_123"], {}, StringIO())
