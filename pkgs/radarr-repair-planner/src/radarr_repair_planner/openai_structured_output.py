from __future__ import annotations

import json
from typing import Any

from pydantic_ai.profiles.openai import OpenAIJsonSchemaTransformer

from .contracts import decision_schema

DECISION_FIELD = "decision"
SCHEMA_INSTRUCTION = """\
The authoritative schema for the `decision` field follows. Return only one JSON
object whose sole field is `decision`, containing a value that validates against
this schema. Do not include Markdown fences or surrounding text.
"""


class OpenAIStructuredOutputError(ValueError):
    """An OpenAI structured response that does not contain a decision."""


def openai_decision_schema() -> dict[str, Any]:
    """Derive an OpenAI-compatible schema without weakening the local contract."""
    schema = decision_schema()
    definitions = schema.get("$defs")
    alternatives = schema.get("oneOf")
    if not isinstance(definitions, dict) or not isinstance(alternatives, list):
        raise RuntimeError("decision contract does not have the expected root union")

    envelope: dict[str, Any] = {
        "$defs": definitions,
        "type": "object",
        "properties": {
            DECISION_FIELD: {
                "anyOf": alternatives,
            }
        },
        "required": [DECISION_FIELD],
        "additionalProperties": False,
    }
    return OpenAIJsonSchemaTransformer(envelope, strict=True).walk()


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
