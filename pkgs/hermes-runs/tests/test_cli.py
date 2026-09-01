from __future__ import annotations

from collections.abc import Iterator
from io import StringIO

import pytest

from hermes_runs.cli import run
from hermes_runs.client import (
    HermesError,
    HermesHttpError,
    JsonObject,
    RunState,
    RunStatus,
    RunSummary,
    StopResult,
    parse_run_status,
)


class FakeClient:
    def __init__(self, response: JsonObject | None = None, run_id: str = "run_123") -> None:
        self.response = response if response is not None else {"status": "ok"}
        self.run_id = run_id
        self.event_values: list[JsonObject] = []
        self.run_values: list[RunSummary] = []

    def start_run(self, instruction: str) -> str:
        return self.run_id

    def watch_run(self, run_id: str) -> Iterator[JsonObject]:
        yield from self.event_values

    def list_runs(self, limit: int) -> list[RunSummary]:
        return self.run_values

    def get_run(self, run_id: str) -> RunStatus:
        return parse_run_status(self.response)

    def approve_run(self, run_id: str, choice: str, resolve_all: bool) -> JsonObject:
        return {"all": resolve_all, "choice": choice, "run_id": run_id}

    def stop_run(self, run_id: str) -> StopResult:
        raw: JsonObject = {"run_id": run_id, "status": "stopping"}
        return StopResult(run_id=run_id, state=RunState.STOPPING, raw=raw)


def invoke(arguments: list[str], client: FakeClient) -> str:
    output = StringIO()
    assert run(arguments, {}, output, client) == 0
    return output.getvalue()


def test_run_prints_run_id() -> None:
    client = FakeClient()

    assert invoke(["run", "inspect files"], client) == "run_123\n"


def test_list_runs_empty() -> None:
    assert invoke(["list"], FakeClient()) == "no runs found\n"


def test_status_prints_json() -> None:
    client = FakeClient({"run_id": "run_123", "status": "running"})

    assert invoke(["status", "run_123", "--json"], client) == (
        '{\n  "run_id": "run_123",\n  "status": "running"\n}\n'
    )


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

    expected = (
        '{\n  "all": %s,\n  "choice": "once",\n  "run_id": "run_123"\n}\n'
        % str(resolve_all).lower()
    )
    assert invoke(arguments, client) == expected


def test_stop() -> None:
    client = FakeClient()

    assert invoke(["stop", "run_123"], client) == (
        '{\n  "run_id": "run_123",\n  "status": "stopping"\n}\n'
    )


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
