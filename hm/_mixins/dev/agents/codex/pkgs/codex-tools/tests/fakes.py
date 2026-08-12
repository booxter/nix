import json
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.json import JsonObject
from codex_tools.usage import PersonalUsage
from codex_tools.work_usage import WorkUsage


@dataclass(frozen=True)
class JsonRequest:
    url: str
    headers: dict[str, str]


@dataclass
class FakeJsonHttpClient:
    responses: dict[str, JsonObject | CodexToolsError]
    requests: list[JsonRequest] = field(default_factory=list)

    def get_json(self, url: str, *, headers: dict[str, str]) -> JsonObject:
        self.requests.append(JsonRequest(url=url, headers=headers))
        response = self.responses[url]
        if isinstance(response, CodexToolsError):
            raise response
        return response


@dataclass
class RecordingSketchybar:
    calls: list[list[str]] = field(default_factory=list)
    error: Exception | None = None

    def run(self, arguments: Sequence[str]) -> None:
        self.calls.append(list(arguments))
        if self.error is not None:
            raise self.error


@dataclass
class FakePersonalUsageService:
    usage: PersonalUsage | None = None
    error: Exception | None = None
    calls: list[tuple[CodexAuth, float]] = field(default_factory=list)

    def fetch(self, auth: CodexAuth, *, now: float) -> PersonalUsage:
        self.calls.append((auth, now))
        if self.error is not None:
            raise self.error
        if self.usage is None:
            raise AssertionError("fake usage was not configured")
        return self.usage


@dataclass
class FakeWorkUsageService:
    usage: WorkUsage | None = None
    error: Exception | None = None
    calls: list[tuple[CodexAuth, float]] = field(default_factory=list)

    def fetch(self, auth: CodexAuth, *, now: float) -> WorkUsage:
        self.calls.append((auth, now))
        if self.error is not None:
            raise self.error
        if self.usage is None:
            raise AssertionError("fake usage was not configured")
        return self.usage


def sketchybar_properties(arguments: Sequence[str]) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    current: str | None = None
    iterator = iter(arguments)
    for argument in iterator:
        if argument == "--set":
            current = next(iterator)
            result.setdefault(current, {})
        elif current is not None:
            name, separator, value = argument.partition("=")
            if separator != "=":
                raise AssertionError(argument)
            result[current][name] = value
    return result


def write_codex_auth(home: Path, *, account_id: str | None = None) -> None:
    tokens = {"access_token": "token"}
    if account_id is not None:
        tokens["account_id"] = account_id
    path = home / ".codex" / "auth.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"tokens": tokens}), encoding="utf-8")
