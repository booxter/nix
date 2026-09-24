from __future__ import annotations

import json
from dataclasses import dataclass

from .decision_validation import DecisionViolation
from .lidarr_case_models import LidarrRepairCaseV3
from .lidarr_contracts import decode_decision, encode_case, encode_decision
from .lidarr_decision_models import LidarrRepairDecisionV3
from .model_projection import (
    MODEL_CASE_ID,
    IdentifierAliases,
    compact_json,
    identifier,
    objects,
    transform,
)

OMITTED_FIELDS = frozenset({"download_ref", "fingerprint", "foreign_release_id", "queue_id"})
OMITTED_CAPABILITY_FIELDS = frozenset({"action", "album_id", "artifact_ids", "track_ids"})


def _integer(item: dict[str, object], field: str) -> int:
    value = item.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"encoded Lidarr repair case has invalid {field}")
    return value


def _integer_list(item: dict[str, object], field: str) -> list[int]:
    value = item.get(field)
    if not isinstance(value, list) or not all(
        isinstance(entry, int) and not isinstance(entry, bool) for entry in value
    ):
        raise ValueError(f"encoded Lidarr repair case has invalid {field}")
    return value


def _string_list(item: dict[str, object], field: str) -> list[str]:
    value = item.get(field)
    if not isinstance(value, list) or not all(isinstance(entry, str) for entry in value):
        raise ValueError(f"encoded Lidarr repair case has invalid {field}")
    return value


def _validate_capabilities(value: object) -> None:
    artifacts = {identifier(artifact, "artifact_id") for artifact in objects(value, "artifacts")}
    tracks = objects(value, "tracks")
    releases = {_integer(release, "release_id") for release in objects(value, "releases")}
    if not isinstance(value, dict) or not isinstance(value.get("album"), dict):
        raise ValueError("encoded Lidarr repair case has invalid album")
    album_id = _integer(value["album"], "album_id")

    for capability in objects(value, "capabilities"):
        if capability.get("action") != "import_missing_tracks_v1":
            raise ValueError("Lidarr capability has an unsupported action")
        release_id = _integer(capability, "release_id")
        if release_id not in releases:
            raise ValueError("Lidarr capability references an unknown release")
        if _integer(capability, "album_id") != album_id:
            raise ValueError("Lidarr capability does not match the offered album")
        if set(_string_list(capability, "artifact_ids")) != artifacts:
            raise ValueError("Lidarr capability does not offer every artifact")
        missing_tracks = {
            _integer(track, "track_id")
            for track in tracks
            if _integer(track, "release_id") == release_id and track.get("has_file") is False
        }
        if set(_integer_list(capability, "track_ids")) != missing_tracks:
            raise ValueError("Lidarr capability does not match the release's missing tracks")


@dataclass(frozen=True)
class LidarrProjection:
    case_content: str
    identifiers: IdentifierAliases

    def project_correction(
        self,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[DecisionViolation, ...]:
        return self.identifiers.project_correction(correction)

    def restore_decision(self, decision: LidarrRepairDecisionV3) -> LidarrRepairDecisionV3:
        value = json.loads(encode_decision(decision))
        restored = self.identifiers.restore(value)
        return decode_decision(compact_json(restored).encode())


def project_case(repair_case: LidarrRepairCaseV3) -> LidarrProjection:
    value: object = json.loads(encode_case(repair_case))
    _validate_capabilities(value)
    aliases = {identifier(value, "case_id"): MODEL_CASE_ID}
    aliases.update(
        {
            identifier(capability, "capability_id"): f"capability:{index}"
            for index, capability in enumerate(objects(value, "capabilities"), 1)
        }
    )
    identifiers = IdentifierAliases.create(aliases)
    projected = transform(value, aliases, OMITTED_FIELDS)
    for capability in objects(projected, "capabilities"):
        for field in OMITTED_CAPABILITY_FIELDS:
            capability.pop(field, None)
    return LidarrProjection(
        case_content=compact_json(projected),
        identifiers=identifiers,
    )
