from __future__ import annotations

from .decision_validation import (
    DecisionViolation,
    ViolationCode,
    validate_object_against_action_schema,
)
from .lidarr_case_models import LidarrRepairCaseV2
from .lidarr_contracts import decision_schema
from .lidarr_decision_models import (
    ImportMissingTracks,
    LidarrRepairDecisionV2,
    NoRepair,
)


def validate_decision_object(value: dict[str, object]) -> tuple[DecisionViolation, ...]:
    return validate_object_against_action_schema(
        value,
        decision_schema(),
        {
            "no_repair": "noRepair",
            "import_missing_tracks_v1": "importMissingTracks",
        },
    )


def _invalid(
    path: tuple[str | int, ...],
    actual: tuple[str, ...],
    allowed: tuple[str, ...],
) -> DecisionViolation:
    return DecisionViolation(
        code=ViolationCode.INVALID_FIELD,
        path=path,
        rejected_values=actual,
        allowed_values=allowed,
    )


def _reference_ids(repair_case: LidarrRepairCaseV2) -> tuple[str, ...]:
    return tuple(
        sorted(
            {
                *(item.artifact_id.root for item in repair_case.artifacts),
                *(item.capability_id.root for item in repair_case.capabilities),
            }
        )
    )


def validate_decision_for_case(
    repair_case: LidarrRepairCaseV2,
    decision: LidarrRepairDecisionV2,
) -> tuple[DecisionViolation, ...]:
    value = decision.root
    violations: list[DecisionViolation] = []
    if value.case_id.root != repair_case.case_id.root:
        violations.append(
            DecisionViolation(
                code=ViolationCode.CASE_ID_MISMATCH,
                path=("case_id",),
                rejected_values=(value.case_id.root,),
                allowed_values=(repair_case.case_id.root,),
            )
        )

    references = _reference_ids(repair_case)
    unknown_references = tuple(
        sorted(
            reference.root for reference in value.evidence_refs if reference.root not in references
        )
    )
    if unknown_references:
        violations.append(
            DecisionViolation(
                code=ViolationCode.UNKNOWN_EVIDENCE,
                path=("evidence_refs",),
                rejected_values=unknown_references,
                allowed_values=references,
            )
        )
    if isinstance(value, NoRepair):
        return tuple(violations)

    assert isinstance(value, ImportMissingTracks)
    capability = next(
        (
            item
            for item in repair_case.capabilities
            if item.capability_id.root == value.capability_id.root
        ),
        None,
    )
    if capability is None:
        violations.append(
            DecisionViolation(
                code=ViolationCode.UNKNOWN_CAPABILITY,
                path=("capability_id",),
                rejected_values=(value.capability_id.root,),
                allowed_values=tuple(item.capability_id.root for item in repair_case.capabilities),
            )
        )
        return tuple(violations)

    album_id = str(value.album_id.root)
    allowed_album = (str(capability.album_id.root),)
    if album_id not in allowed_album:
        violations.append(_invalid(("album_id",), (album_id,), allowed_album))

    release_id = str(value.release_id.root)
    allowed_releases = (str(capability.release_id.root),)
    if release_id not in allowed_releases:
        violations.append(_invalid(("release_id",), (release_id,), allowed_releases))

    artifacts = tuple(mapping.artifact_id.root for mapping in value.mappings)
    allowed_artifacts = tuple(item.root for item in capability.artifact_ids)
    if len(set(artifacts)) != len(artifacts) or not set(artifacts).issubset(allowed_artifacts):
        violations.append(_invalid(("mappings", "artifact_id"), artifacts, allowed_artifacts))

    tracks = tuple(str(mapping.track_id.root) for mapping in value.mappings)
    allowed_tracks = tuple(str(item.root) for item in capability.track_ids.root)
    if len(set(tracks)) != len(tracks) or set(tracks) != set(allowed_tracks):
        violations.append(_invalid(("mappings", "track_id"), tracks, allowed_tracks))

    return tuple(violations)
