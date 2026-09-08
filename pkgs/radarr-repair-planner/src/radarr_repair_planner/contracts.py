from __future__ import annotations

import json
from importlib.resources import files
from typing import Any, NoReturn, cast

from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]
from jsonschema.exceptions import (  # type: ignore[import-untyped]
    ValidationError as SchemaValidationError,
)
from pydantic import BaseModel
from pydantic import ValidationError as ModelValidationError

from .case_models import RepairCaseV1 as RepairCaseV1
from .decision_models import RepairDecisionV1 as RepairDecisionV1


class ContractError(ValueError):
    """The supplied value does not satisfy a Radarr repair contract."""


def _load_schema(name: str) -> dict[str, Any]:
    resource = files(__package__).joinpath("schemas", name)
    value = json.loads(resource.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"contract schema {name} is not an object")
    return cast(dict[str, Any], value)


CASE_VALIDATOR = Draft202012Validator(
    _load_schema("repair-case.schema.json"),
    format_checker=FormatChecker(),
)
DECISION_VALIDATOR = Draft202012Validator(
    _load_schema("repair-decision.schema.json"),
    format_checker=FormatChecker(),
)


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"invalid JSON constant {value}")


def _decode[Model: BaseModel](
    payload: bytes,
    validator: Draft202012Validator,
    model: type[Model],
) -> Model:
    try:
        value = json.loads(payload, parse_constant=_reject_json_constant)
    except (UnicodeDecodeError, ValueError) as error:
        raise ContractError(f"invalid JSON: {error}") from error
    try:
        validator.validate(value)
    except SchemaValidationError as error:
        raise ContractError(f"contract validation failed: {error.message}") from error
    try:
        return model.model_validate(value)
    except ModelValidationError as error:
        raise ContractError(f"typed model validation failed: {error}") from error


def decode_case(payload: bytes) -> RepairCaseV1:
    return _decode(payload, CASE_VALIDATOR, RepairCaseV1)


def decode_decision(payload: bytes) -> RepairDecisionV1:
    return _decode(payload, DECISION_VALIDATOR, RepairDecisionV1)


def encode_decision(decision: RepairDecisionV1) -> bytes:
    value = decision.model_dump(mode="json", by_alias=True)
    try:
        DECISION_VALIDATOR.validate(value)
    except SchemaValidationError as error:
        raise ContractError(f"contract validation failed: {error.message}") from error
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
