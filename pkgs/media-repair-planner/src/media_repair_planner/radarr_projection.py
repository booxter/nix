from __future__ import annotations

import json
from dataclasses import dataclass

from .case_models import RepairCaseV3
from .contracts import decode_decision, encode_case, encode_decision
from .decision_models import RepairDecisionV3
from .decision_validation import DecisionViolation

OMITTED_FIELDS = frozenset({"download_ref", "fingerprint", "queue_id"})


def _objects(value: object, field: str) -> list[dict[str, object]]:
    if not isinstance(value, dict):
        raise ValueError("encoded Radarr repair case is not an object")
    items = value.get(field)
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ValueError(f"encoded Radarr repair case has invalid {field}")
    return items


def _identifier(item: dict[str, object], field: str) -> str:
    value = item.get(field)
    if not isinstance(value, str):
        raise ValueError(f"encoded Radarr repair case has invalid {field}")
    return value


def _collect_evidence_ids(value: object, identifiers: list[str]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "evidence_id" and isinstance(item, str) and item not in identifiers:
                identifiers.append(item)
            _collect_evidence_ids(item, identifiers)
    elif isinstance(value, list):
        for item in value:
            _collect_evidence_ids(item, identifiers)


def _transform(
    value: object,
    replacements: dict[str, str],
    omitted_fields: frozenset[str] = frozenset(),
) -> object:
    if isinstance(value, dict):
        return {
            key: _transform(item, replacements, omitted_fields)
            for key, item in value.items()
            if isinstance(key, str) and key not in omitted_fields
        }
    if isinstance(value, list):
        return [_transform(item, replacements, omitted_fields) for item in value]
    if isinstance(value, str):
        return replacements.get(value, value)
    return value


def _compact_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


@dataclass(frozen=True)
class RadarrProjection:
    case_content: str
    aliases: dict[str, str]
    canonical_ids: dict[str, str]

    def project_correction(
        self,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[DecisionViolation, ...]:
        return tuple(
            DecisionViolation(
                code=item.code,
                path=item.path,
                rejected_values=tuple(
                    self.aliases.get(value, value) for value in item.rejected_values
                ),
                allowed_values=tuple(
                    self.aliases.get(value, value) for value in item.allowed_values
                ),
            )
            for item in correction
        )

    def restore_decision(self, decision: RepairDecisionV3) -> RepairDecisionV3:
        value = json.loads(encode_decision(decision))
        restored = _transform(value, self.canonical_ids)
        return decode_decision(_compact_json(restored).encode())


def project_case(repair_case: RepairCaseV3) -> RadarrProjection:
    value: object = json.loads(encode_case(repair_case))
    aliases: dict[str, str] = {}

    for index, item in enumerate(_objects(value, "files"), 1):
        aliases[_identifier(item, "file_id")] = f"file:{index}"
    for index, item in enumerate(_objects(value, "capabilities"), 1):
        aliases[_identifier(item, "capability_id")] = f"capability:{index}"

    evidence_ids: list[str] = []
    _collect_evidence_ids(value, evidence_ids)
    for index, identifier in enumerate(evidence_ids, 1):
        aliases[identifier] = f"evidence:{index}"

    projected = _transform(value, aliases, OMITTED_FIELDS)
    return RadarrProjection(
        case_content=_compact_json(projected),
        aliases=aliases,
        canonical_ids={alias: canonical for canonical, alias in aliases.items()},
    )
