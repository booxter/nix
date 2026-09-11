from __future__ import annotations

import json

import pytest
from jsonschema import Draft202012Validator  # type: ignore[import-untyped]
from radarr_repair_planner.contracts import decision_schema
from radarr_repair_planner.openai_structured_output import (
    DECISION_FIELD,
    OpenAIStructuredOutputError,
    openai_decision_schema,
    unwrap_openai_decision,
)


def keywords(value: object) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {key for child in value.values() for key in keywords(child)}
    if isinstance(value, list):
        return {key for child in value for key in keywords(child)}
    return set()


def test_openai_schema_wraps_and_adapts_authoritative_contract() -> None:
    authoritative = decision_schema()

    adapted = openai_decision_schema()

    Draft202012Validator.check_schema(adapted)
    assert adapted["type"] == "object"
    assert adapted["required"] == [DECISION_FIELD]
    assert adapted["additionalProperties"] is False
    assert "anyOf" in adapted["properties"][DECISION_FIELD]
    assert "oneOf" not in keywords(adapted)
    assert "uniqueItems" not in keywords(adapted)
    assert "uniqueItems" in keywords(authoritative)
    assert decision_schema() == authoritative


def test_unwrap_openai_decision_returns_inner_json() -> None:
    decision = {"action": "no_repair", "case_id": "sha256:" + "a" * 64}

    unwrapped = unwrap_openai_decision(json.dumps({DECISION_FIELD: decision}))

    assert json.loads(unwrapped) == decision


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("not JSON", "not valid JSON"),
        ("[]", "not an object"),
        ("{}", "only the decision field"),
        ('{"decision":{},"extra":true}', "only the decision field"),
    ],
)
def test_unwrap_openai_decision_rejects_invalid_envelope(value: str, message: str) -> None:
    with pytest.raises(OpenAIStructuredOutputError, match=message):
        unwrap_openai_decision(value)
