from __future__ import annotations

import json
from importlib.resources import files
from typing import Any, cast

from .json_contract import ContractError as ContractError
from .json_contract import JsonContract
from .lidarr_case_models import LidarrRepairCaseV2 as LidarrRepairCaseV2
from .lidarr_decision_models import LidarrRepairDecisionV2 as LidarrRepairDecisionV2


def _load_schema(name: str) -> dict[str, Any]:
    resource = files(__package__).joinpath("schemas", name)
    value = json.loads(resource.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"contract schema {name} is not an object")
    return cast(dict[str, Any], value)


CASE_CONTRACT = JsonContract(
    _load_schema("lidarr-repair-case.schema.json"),
    LidarrRepairCaseV2,
)
DECISION_CONTRACT = JsonContract(
    _load_schema("lidarr-repair-decision.schema.json"),
    LidarrRepairDecisionV2,
)


def decode_case(payload: bytes) -> LidarrRepairCaseV2:
    return CASE_CONTRACT.decode(payload)


def decode_decision(payload: bytes) -> LidarrRepairDecisionV2:
    return DECISION_CONTRACT.decode(payload)


def encode_case(repair_case: LidarrRepairCaseV2) -> bytes:
    return CASE_CONTRACT.encode(repair_case)


def encode_decision(decision: LidarrRepairDecisionV2) -> bytes:
    return DECISION_CONTRACT.encode(decision)


def decision_schema() -> dict[str, Any]:
    return DECISION_CONTRACT.schema_copy()
