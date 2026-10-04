from __future__ import annotations

import json

from pydantic import BaseModel, ConfigDict, Field, JsonValue

from .planning_core import PlanningContext
from .prompt import RECONSIDERATION_INSTRUCTION


class PlanningRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    repair_case: JsonValue
    prior_decision: JsonValue | None = None
    operator_guidance: str = Field(default="", max_length=2_000)
    maximum_runtime_difference_ms: int = Field(default=0, ge=0, le=3_600_000)

    def context(self) -> PlanningContext | None:
        if not self.operator_guidance and not self.maximum_runtime_difference_ms:
            return None

        # Operator intent is policy input, never additional media evidence.
        content: dict[str, JsonValue] = {
            "operator_guidance": {
                "authority": "policy_override",
                "media_evidence": False,
                "text": self.operator_guidance,
            },
            "maximum_runtime_difference_ms": self.maximum_runtime_difference_ms or None,
            "prior_decision": self.prior_decision,
        }
        return PlanningContext(
            system_instruction=RECONSIDERATION_INSTRUCTION,
            user_content=json.dumps(content),
        )
