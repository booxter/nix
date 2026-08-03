from __future__ import annotations

import pytest

from sops_tools.errors import ToolError
from sops_tools.model import KeyPath, deep_merge, scalar_leaves, value_at


def test_key_path_preserves_literal_dots_and_dashes() -> None:
    path = KeyPath.parse("/special/key.with.dots-and-dashes")

    assert path.segments == ("special", "key.with.dots-and-dashes")
    assert path.sops_index() == '["special"]["key.with.dots-and-dashes"]'


@pytest.mark.parametrize("raw", ["", "/", "///", ".///"])
def test_key_path_rejects_empty_paths(raw: str) -> None:
    with pytest.raises(ToolError, match="KEY_PATH must not be empty"):
        KeyPath.parse(raw)


def test_value_at_distinguishes_null_from_a_missing_path() -> None:
    document = {"present": None}

    assert value_at(document, KeyPath.parse("present")) is None
    with pytest.raises(ToolError, match="Path not found"):
        value_at(document, KeyPath.parse("missing"))


def test_deep_merge_preserves_existing_values_and_replaces_arrays() -> None:
    defaults = {"shared": "template", "nested": {"new": 1}, "items": ["old"]}
    current = {"shared": "secret", "nested": {"keep": 2}, "items": ["current"]}

    assert deep_merge(defaults, current) == {
        "shared": "secret",
        "nested": {"new": 1, "keep": 2},
        "items": ["current"],
    }


def test_scalar_leaves_include_array_indexes_but_not_empty_containers() -> None:
    leaves = scalar_leaves({"items": ["one"], "empty": {}})

    assert leaves == [(KeyPath.from_segments("items", 0), "one")]
