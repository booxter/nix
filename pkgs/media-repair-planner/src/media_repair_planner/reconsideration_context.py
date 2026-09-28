from __future__ import annotations

import json

from .planning_core import PlanningContext
from .prompt import RECONSIDERATION_INSTRUCTION


def build_reconsideration_context(
    request_id: str,
    guidance: str,
    prior_decision: bytes,
) -> PlanningContext:
    content = json.dumps(
        {
            "reconsideration": {
                "request_id": request_id,
                "operator_guidance": {
                    "authority": "policy_override",
                    "media_evidence": False,
                    "text": guidance,
                },
                "prior_decision": json.loads(prior_decision),
            }
        },
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return PlanningContext(
        system_instruction=RECONSIDERATION_INSTRUCTION,
        user_content=content,
    )
