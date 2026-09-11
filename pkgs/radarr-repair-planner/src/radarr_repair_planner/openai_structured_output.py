from __future__ import annotations

import json

from pydantic import BaseModel, ConfigDict

from .decision_models import RepairDecisionV1

DECISION_FIELD = "decision"
SCHEMA_INSTRUCTION = """\
The authoritative schema for the `decision` field follows. Return only one JSON
object whose sole field is `decision`, containing a value that validates against
this schema. Do not include Markdown fences or surrounding text.
"""


class OpenAIStructuredOutputError(ValueError):
    """An OpenAI structured response that does not contain a decision."""


class OpenAIDecisionEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    decision: RepairDecisionV1


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
