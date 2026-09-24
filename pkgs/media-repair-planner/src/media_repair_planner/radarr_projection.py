from __future__ import annotations

import json
from dataclasses import dataclass

from .case_models import RepairCaseV3
from .contracts import decode_decision, encode_case, encode_decision
from .decision_models import RepairDecisionV3
from .decision_validation import DecisionViolation
from .model_projection import (
    IdentifierAliases,
    compact_json,
    identifier,
    objects,
    transform,
)

OMITTED_FIELDS = frozenset({"download_ref", "fingerprint", "queue_id"})


def _collect_evidence_ids(value: object, identifiers: list[str]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "evidence_id" and isinstance(item, str) and item not in identifiers:
                identifiers.append(item)
            _collect_evidence_ids(item, identifiers)
    elif isinstance(value, list):
        for item in value:
            _collect_evidence_ids(item, identifiers)


@dataclass(frozen=True)
class RadarrProjection:
    case_content: str
    identifiers: IdentifierAliases

    def project_correction(
        self,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[DecisionViolation, ...]:
        return self.identifiers.project_correction(correction)

    def restore_decision(self, decision: RepairDecisionV3) -> RepairDecisionV3:
        value = json.loads(encode_decision(decision))
        restored = self.identifiers.restore(value)
        return decode_decision(compact_json(restored).encode())


def project_case(repair_case: RepairCaseV3) -> RadarrProjection:
    value: object = json.loads(encode_case(repair_case))
    aliases: dict[str, str] = {}

    for index, item in enumerate(objects(value, "files"), 1):
        aliases[identifier(item, "file_id")] = f"file:{index}"
    for index, item in enumerate(objects(value, "capabilities"), 1):
        aliases[identifier(item, "capability_id")] = f"capability:{index}"

    evidence_ids: list[str] = []
    _collect_evidence_ids(value, evidence_ids)
    for index, evidence_id in enumerate(evidence_ids, 1):
        aliases[evidence_id] = f"evidence:{index}"

    identifiers = IdentifierAliases.create(aliases)
    projected = transform(value, aliases, OMITTED_FIELDS)
    return RadarrProjection(
        case_content=compact_json(projected),
        identifiers=identifiers,
    )
