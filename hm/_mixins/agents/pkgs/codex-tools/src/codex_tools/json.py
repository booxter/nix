import json
from typing import cast

from codex_tools.errors import CodexToolsError

JsonObject = dict[str, object]


def decode_object(text: str, *, source: str) -> JsonObject:
    try:
        value: object = json.loads(text)
    except json.JSONDecodeError as error:
        raise CodexToolsError(f"Invalid JSON from {source}: {error.msg}") from error
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise CodexToolsError(f"Expected a JSON object from {source}")
    return cast(JsonObject, value)
