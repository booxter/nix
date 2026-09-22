"""Typed boundary for the Radarr repair planner."""

from .contracts import (
    ContractError,
    RepairCaseV2,
    RepairDecisionV2,
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)
from .ollama_model import OllamaConfigurationError, OllamaDecisionModel, OllamaSettings
from .planning import DecisionModel, DecisionModelError, Planner, PlanningOutcome

__all__ = [
    "ContractError",
    "DecisionModel",
    "DecisionModelError",
    "OllamaConfigurationError",
    "OllamaDecisionModel",
    "OllamaSettings",
    "Planner",
    "PlanningOutcome",
    "RepairCaseV2",
    "RepairDecisionV2",
    "decode_case",
    "decode_decision",
    "encode_case",
    "encode_decision",
]
