from dataclasses import dataclass, field

from codex_tools.errors import CodexToolsError
from codex_tools.json import JsonObject


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
