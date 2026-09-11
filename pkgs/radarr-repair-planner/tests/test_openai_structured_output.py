from __future__ import annotations

import json

import pytest
from radarr_repair_planner.openai_structured_output import (
    DECISION_FIELD,
    OpenAIDecisionEnvelope,
    OpenAIStructuredOutputError,
    unwrap_openai_decision,
)


def keywords(value: object) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {key for child in value.values() for key in keywords(child)}
    if isinstance(value, list):
        return {key for child in value for key in keywords(child)}
    return set()


def test_openai_envelope_schema_has_explicit_const_types() -> None:
    schema = OpenAIDecisionEnvelope.model_json_schema()

    assert schema["type"] == "object"
    assert schema["required"] == [DECISION_FIELD]
    assert schema["additionalProperties"] is False
    assert "oneOf" not in keywords(schema)

    def assert_const_types(value: object) -> None:
        if isinstance(value, dict):
            if "const" in value:
                assert "type" in value
            for child in value.values():
                assert_const_types(child)
        elif isinstance(value, list):
            for child in value:
                assert_const_types(child)

    assert_const_types(schema)


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
