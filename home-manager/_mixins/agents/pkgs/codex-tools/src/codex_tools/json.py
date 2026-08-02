import json
from collections.abc import Mapping
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


def object_value(source: Mapping[str, object], key: str) -> JsonObject | None:
    value = source.get(key)
    if not isinstance(value, dict) or not all(isinstance(item, str) for item in value):
        return None
    return cast(JsonObject, value)


def object_list(source: Mapping[str, object], key: str) -> list[JsonObject]:
    value = source.get(key)
    if not isinstance(value, list):
        return []
    result: list[JsonObject] = []
    for item in value:
        if isinstance(item, dict) and all(isinstance(name, str) for name in item):
            result.append(cast(JsonObject, item))
    return result


def number_value(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def integer_value(value: object) -> int | None:
    number = number_value(value)
    return int(number) if number is not None else None


def string_value(value: object) -> str | None:
    return value if isinstance(value, str) else None


def boolean_value(value: object) -> bool | None:
    return value if isinstance(value, bool) else None
