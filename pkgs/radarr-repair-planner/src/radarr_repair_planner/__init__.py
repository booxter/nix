"""Typed boundary for the Radarr repair planner."""

from .contracts import (
    ContractError,
    RepairCaseV3,
    RepairDecisionV3,
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
    "RepairCaseV3",
    "RepairDecisionV3",
    "decode_case",
    "decode_decision",
    "encode_case",
    "encode_decision",
]
