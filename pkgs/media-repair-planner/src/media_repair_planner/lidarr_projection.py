from __future__ import annotations

import json
from dataclasses import dataclass

from .decision_validation import DecisionViolation
from .lidarr_case_models import LidarrRepairCaseV3
from .lidarr_contracts import decode_decision, encode_case, encode_decision
from .lidarr_decision_models import LidarrRepairDecisionV3

OMITTED_FIELDS = frozenset({"download_ref", "fingerprint", "foreign_release_id", "queue_id"})
OMITTED_CAPABILITY_FIELDS = frozenset({"action", "album_id", "artifact_ids", "track_ids"})


def _objects(value: object, field: str) -> list[dict[str, object]]:
    if not isinstance(value, dict):
        raise ValueError("encoded Lidarr repair case is not an object")
    items = value.get(field)
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ValueError(f"encoded Lidarr repair case has invalid {field}")
    return items


def _identifier(item: dict[str, object], field: str) -> str:
    value = item.get(field)
    if not isinstance(value, str):
        raise ValueError(f"encoded Lidarr repair case has invalid {field}")
    return value


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


def _validate_capabilities(value: object) -> None:
    artifacts = {_identifier(artifact, "artifact_id") for artifact in _objects(value, "artifacts")}
    tracks = _objects(value, "tracks")
    releases = {_integer(release, "release_id") for release in _objects(value, "releases")}
    if not isinstance(value, dict) or not isinstance(value.get("album"), dict):
        raise ValueError("encoded Lidarr repair case has invalid album")
    album_id = _integer(value["album"], "album_id")

    for capability in _objects(value, "capabilities"):
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

    def restore_decision(self, decision: LidarrRepairDecisionV3) -> LidarrRepairDecisionV3:
        value = json.loads(encode_decision(decision))
        restored = _transform(value, self.canonical_ids)
        return decode_decision(_compact_json(restored).encode())


def project_case(repair_case: LidarrRepairCaseV3) -> LidarrProjection:
    value: object = json.loads(encode_case(repair_case))
    _validate_capabilities(value)
    aliases = {
        _identifier(capability, "capability_id"): f"capability:{index}"
        for index, capability in enumerate(_objects(value, "capabilities"), 1)
    }
    projected = _transform(value, aliases, OMITTED_FIELDS)
    for capability in _objects(projected, "capabilities"):
        for field in OMITTED_CAPABILITY_FIELDS:
            capability.pop(field, None)
    return LidarrProjection(
        case_content=_compact_json(projected),
        aliases=aliases,
        canonical_ids={alias: canonical for canonical, alias in aliases.items()},
    )
