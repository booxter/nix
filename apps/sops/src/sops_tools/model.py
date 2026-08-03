from __future__ import annotations

import json
from dataclasses import dataclass
from typing import TypeAlias, TypeGuard, cast

from .errors import ToolError

JsonScalar: TypeAlias = None | bool | int | float | str
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
PathSegment: TypeAlias = str | int


def is_json_value(value: object) -> TypeGuard[JsonValue]:
    if value is None or isinstance(value, bool | int | float | str):
        return True
    if isinstance(value, list):
        return all(is_json_value(item) for item in value)
    if isinstance(value, dict):
        return all(
            isinstance(key, str) and is_json_value(item) for key, item in value.items()
        )
    return False


def require_json_value(value: object, *, source: str) -> JsonValue:
    if not is_json_value(value):
        raise ToolError(f"{source} contains a non-JSON YAML value.")
    return value


@dataclass(frozen=True)
class KeyPath:
    segments: tuple[PathSegment, ...]

    def __post_init__(self) -> None:
        if not self.segments:
            raise ToolError("KEY_PATH must not be empty.")
        if any(isinstance(segment, str) and not segment for segment in self.segments):
            raise ToolError("KEY_PATH segments must not be empty.")
        if any(isinstance(segment, int) and segment < 0 for segment in self.segments):
            raise ToolError("KEY_PATH array indexes must not be negative.")

    @classmethod
    def parse(cls, raw: str) -> KeyPath:
        normalized = raw.removeprefix(".").removeprefix("/")
        segments = tuple(segment for segment in normalized.split("/") if segment)
        if not segments:
            raise ToolError("KEY_PATH must not be empty.")
        return cls(segments)

    @classmethod
    def from_segments(cls, *segments: PathSegment) -> KeyPath:
        return cls(segments)

    def child(self, segment: PathSegment) -> KeyPath:
        return KeyPath((*self.segments, segment))

    def sops_index(self) -> str:
        return "".join(
            f"[{segment}]" if isinstance(segment, int) else f"[{json.dumps(segment)}]"
            for segment in self.segments
        )

    def display(self) -> str:
        return "/".join(str(segment) for segment in self.segments)


_MISSING = object()


def value_at(document: JsonValue, path: KeyPath) -> JsonValue:
    current: JsonValue | object = document
    for segment in path.segments:
        if isinstance(segment, str) and isinstance(current, dict):
            current = current.get(segment, _MISSING)
        elif isinstance(segment, int) and isinstance(current, list):
            current = current[segment] if segment < len(current) else _MISSING
        else:
            current = _MISSING
        if current is _MISSING:
            raise ToolError(f"Path not found: {path.display()}")
    return cast(JsonValue, current)


def has_path(document: JsonValue, path: KeyPath) -> bool:
    try:
        value_at(document, path)
    except ToolError:
        return False
    return True


def deep_merge(defaults: JsonValue, overrides: JsonValue) -> JsonValue:
    if not isinstance(defaults, dict) or not isinstance(overrides, dict):
        return overrides
    merged: dict[str, JsonValue] = {key: value for key, value in defaults.items()}
    for key, value in overrides.items():
        if key in merged:
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def scalar_leaves(
    value: JsonValue, path: KeyPath | None = None
) -> list[tuple[KeyPath, JsonScalar]]:
    leaves: list[tuple[KeyPath, JsonScalar]] = []
    if isinstance(value, dict):
        for key, item in value.items():
            child = KeyPath.from_segments(key) if path is None else path.child(key)
            leaves.extend(scalar_leaves(item, child))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            child = KeyPath.from_segments(index) if path is None else path.child(index)
            leaves.extend(scalar_leaves(item, child))
    elif path is not None:
        leaves.append((path, value))
    return leaves
