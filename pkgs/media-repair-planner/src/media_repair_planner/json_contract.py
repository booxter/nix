from __future__ import annotations

import json
from copy import deepcopy
from dataclasses import dataclass, field
from typing import Any, NoReturn

from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]
from jsonschema.exceptions import (  # type: ignore[import-untyped]
    ValidationError as SchemaValidationError,
)
from pydantic import BaseModel
from pydantic import ValidationError as ModelValidationError


class ContractError(ValueError):
    """The supplied value does not satisfy a media-repair contract."""


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"invalid JSON constant {value}")


@dataclass(frozen=True)
class JsonContract[Model: BaseModel]:
    schema: dict[str, Any]
    model: type[Model]
    _validator: Draft202012Validator = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "_validator",
            Draft202012Validator(self.schema, format_checker=FormatChecker()),
        )

    def decode(self, payload: bytes) -> Model:
        try:
            value = json.loads(payload, parse_constant=_reject_json_constant)
        except (UnicodeDecodeError, ValueError) as error:
            raise ContractError(f"invalid JSON: {error}") from error
        try:
            self._validator.validate(value)
        except SchemaValidationError as error:
            raise ContractError(f"contract validation failed: {error.message}") from error
        try:
            return self.model.model_validate(value)
        except ModelValidationError as error:
            raise ContractError(f"typed model validation failed: {error}") from error

    def encode(self, model: Model) -> bytes:
        value = model.model_dump(mode="json", by_alias=True, exclude_unset=True)
        try:
            self._validator.validate(value)
        except SchemaValidationError as error:
            raise ContractError(f"contract validation failed: {error.message}") from error
        return json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()

    def schema_copy(self) -> dict[str, Any]:
        return deepcopy(self.schema)
