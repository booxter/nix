from __future__ import annotations

import json
from functools import cache

from pydantic import BaseModel, ConfigDict, create_model

DECISION_FIELD = "decision"


class OpenAIStructuredOutputError(ValueError):
    """An OpenAI structured response that does not contain a decision."""


@cache
def decision_envelope_model(decision_model: type[BaseModel]) -> type[BaseModel]:
    return create_model(
        decision_model.__name__ + "Envelope",
        __config__=ConfigDict(extra="forbid"),
        decision=(decision_model, ...),
    )


def unwrap_openai_decision(raw_output: str) -> str:
    try:
        value = json.loads(raw_output)
    except json.JSONDecodeError as error:
        raise OpenAIStructuredOutputError("structured envelope was not valid JSON") from error
    if not isinstance(value, dict):
        raise OpenAIStructuredOutputError("structured envelope was not an object")
    if set(value) != {DECISION_FIELD}:
        raise OpenAIStructuredOutputError(
            "structured envelope must contain only the decision field"
        )
    try:
        return json.dumps(value[DECISION_FIELD], allow_nan=False)
    except (TypeError, ValueError) as error:
        raise OpenAIStructuredOutputError("structured decision was not valid JSON") from error
