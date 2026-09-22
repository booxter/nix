from __future__ import annotations

import json
from importlib.resources import files
from typing import Any, cast

from .case_models import RepairCaseV3 as RepairCaseV3
from .decision_models import RepairDecisionV3 as RepairDecisionV3
from .json_contract import ContractError as ContractError
from .json_contract import JsonContract


def _load_schema(name: str) -> dict[str, Any]:
    resource = files(__package__).joinpath("schemas", name)
    value = json.loads(resource.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"contract schema {name} is not an object")
    return cast(dict[str, Any], value)


CASE_SCHEMA = _load_schema("repair-case.schema.json")
DECISION_SCHEMA = _load_schema("repair-decision.schema.json")

CASE_CONTRACT = JsonContract(CASE_SCHEMA, RepairCaseV3)
DECISION_CONTRACT = JsonContract(DECISION_SCHEMA, RepairDecisionV3)


def decode_case(payload: bytes) -> RepairCaseV3:
    return CASE_CONTRACT.decode(payload)


def decode_decision(payload: bytes) -> RepairDecisionV3:
    return DECISION_CONTRACT.decode(payload)


def encode_case(repair_case: RepairCaseV3) -> bytes:
    return CASE_CONTRACT.encode(repair_case)


def encode_decision(decision: RepairDecisionV3) -> bytes:
    return DECISION_CONTRACT.encode(decision)


def decision_schema() -> dict[str, Any]:
    return DECISION_CONTRACT.schema_copy()
