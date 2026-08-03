from collections.abc import Sequence
from dataclasses import dataclass, field

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.json import JsonObject
from codex_tools.usage import PersonalUsage


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
