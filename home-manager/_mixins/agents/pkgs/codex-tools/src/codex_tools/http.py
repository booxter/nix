import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Protocol

from codex_tools.errors import CodexToolsError
from codex_tools.json import JsonObject, decode_object


class JsonHttpClient(Protocol):
    def get_json(self, url: str, *, headers: dict[str, str]) -> JsonObject: ...


@dataclass(frozen=True)
class UrllibJsonHttpClient:
    timeout_seconds: float = 30.0

    def get_json(self, url: str, *, headers: dict[str, str]) -> JsonObject:
        request = urllib.request.Request(
            url,
            headers={"Accept": "application/json", **headers},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read().decode("utf-8")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            raise CodexToolsError(f"Request to {url} failed: {error}") from error
        except UnicodeDecodeError as error:
            raise CodexToolsError(f"Response from {url} is not UTF-8") from error
        return decode_object(body, source=url)
