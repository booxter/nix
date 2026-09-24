from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, JsonValue, StringConstraints

from .decision_validation_core import describe_violation
from .evaluation_runtime import EvaluationSettings
from .lidarr_case_models import LidarrRepairCaseV3
from .lidarr_contracts import decode_case, encode_decision
from .lidarr_decision_models import LidarrRepairDecisionV3
from .lidarr_planning import LidarrPlanner
from .lidarr_validation import validate_decision_for_case
from .planning_core import PlanningOutcome

CaseName = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


class LidarrEvaluationDataError(ValueError):
    """The Lidarr review corpus is absent or malformed."""


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class EvaluationResult(StrictModel):
    case_name: CaseName
    case_id: str
    artist: str
    album: str
    queue_title: str
    queue_messages: list[str]
    run: int
    attempts: int
    attempt_errors: list[str]
    used_fallback: bool
    passed: bool
    violations: list[str]
    decision: dict[str, JsonValue]


class EvaluationReport(StrictModel):
    schema_version: Literal["lidarr-repair-review-report/v1"] = "lidarr-repair-review-report/v1"
    settings: EvaluationSettings
    passed: bool
    results: list[EvaluationResult]


@dataclass(frozen=True)
class CorpusCase:
    name: str
    repair_case: LidarrRepairCaseV3


def load_cases(directory: Path) -> list[CorpusCase]:
    if not directory.is_dir():
        raise LidarrEvaluationDataError("Lidarr case directory is unavailable")
    paths = sorted(directory.glob("*.json"))
    if not paths:
        raise LidarrEvaluationDataError("Lidarr case directory contains no JSON cases")
    if len(paths) > 128:
        raise LidarrEvaluationDataError("Lidarr case directory contains too many cases")

    result: list[CorpusCase] = []
    seen: set[str] = set()
    for path in paths:
        name = path.stem
        if len(name) != 64 or any(character not in "0123456789abcdef" for character in name):
            raise LidarrEvaluationDataError(f"invalid Lidarr case filename: {path.name}")
        repair_case = decode_case(path.read_bytes())
        expected_id = "sha256:" + name
        if repair_case.case_id.root != expected_id:
            raise LidarrEvaluationDataError(
                f"Lidarr case filename does not match case ID: {path.name}"
            )
        if expected_id in seen:
            raise LidarrEvaluationDataError(f"duplicate Lidarr case ID: {expected_id}")
        seen.add(expected_id)
        result.append(CorpusCase(name=name, repair_case=repair_case))
    return result


def evaluate_outcome(
    corpus_case: CorpusCase,
    run: int,
    outcome: PlanningOutcome[LidarrRepairDecisionV3],
) -> EvaluationResult:
    violations = ["planner exhausted its attempts"] if outcome.used_fallback else []
    violations.extend(
        describe_violation(violation)
        for violation in validate_decision_for_case(corpus_case.repair_case, outcome.decision)
    )
    repair_case = corpus_case.repair_case
    return EvaluationResult(
        case_name=corpus_case.name,
        case_id=repair_case.case_id.root,
        artist=repair_case.album.artist.root,
        album=repair_case.album.title.root,
        queue_title=repair_case.queue.title.root,
        queue_messages=[message.root for message in repair_case.queue.messages],
        run=run,
        attempts=outcome.attempts,
        attempt_errors=list(outcome.attempt_errors),
        used_fallback=outcome.used_fallback,
        passed=not violations,
        violations=violations,
        decision=json.loads(encode_decision(outcome.decision)),
    )


async def run_evaluation(
    planner: LidarrPlanner,
    settings: EvaluationSettings,
    corpus: list[CorpusCase],
) -> EvaluationReport:
    if settings.case is not None:
        corpus = [item for item in corpus if item.name == settings.case]
        if not corpus:
            raise LidarrEvaluationDataError(f"unknown Lidarr evaluation case: {settings.case}")

    results: list[EvaluationResult] = []
    for corpus_case in corpus:
        for run in range(1, settings.runs + 1):
            outcome = await planner.plan_with_outcome(corpus_case.repair_case)
            results.append(evaluate_outcome(corpus_case, run, outcome))
    return EvaluationReport(
        settings=settings,
        passed=all(result.passed for result in results),
        results=results,
    )
