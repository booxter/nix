from __future__ import annotations

import json
from copy import deepcopy
from dataclasses import dataclass
from importlib.resources import files
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, JsonValue, StringConstraints, model_validator

from .case_models import RepairCaseV2
from .contracts import decode_case, encode_decision
from .decision_models import Reason, RepairDecisionV2
from .decision_validation import describe_violation, validate_decision_for_case
from .openrouter_model import ReasoningEffort
from .planning import Planner, PlanningOutcome

EvaluationName = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_]*$")]
CaseFilename = Annotated[
    str,
    StringConstraints(pattern=r"^(?:repair-case-[a-z0-9-]+|[0-9a-f]{64})\.json$"),
]


class EvaluationDataError(ValueError):
    """The packaged evaluation corpus is malformed."""


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ExpectedNoRepair(StrictModel):
    action: Literal["no_repair"]
    allowed_reasons: list[Reason] = Field(min_length=1)


class ExpectedJoin(StrictModel):
    action: Literal["join_parts_v1"]
    capability_id: str
    ordered_file_ids: list[str] = Field(min_length=2)


class ExpectedManualImport(StrictModel):
    action: Literal["manual_import_file_v1"]
    capability_id: str
    file_id: str


class ExpectedRemuxBluray(StrictModel):
    action: Literal["remux_bluray_v1"]
    capability_id: str


class ExpectedRemuxDVD(StrictModel):
    action: Literal["remux_dvd_v1"]
    capability_id: str


ExpectedDecision = Annotated[
    ExpectedNoRepair | ExpectedJoin | ExpectedManualImport | ExpectedRemuxBluray | ExpectedRemuxDVD,
    Field(discriminator="action"),
]


class EvaluationCaseSpec(StrictModel):
    name: EvaluationName
    base_case: CaseFilename
    replacements: dict[str, JsonValue] = Field(default_factory=dict)
    expected: ExpectedDecision


class EvaluationManifest(StrictModel):
    schema_version: Literal["radarr-repair-evaluation/v2"]
    cases: list[EvaluationCaseSpec] = Field(min_length=1, max_length=64)

    @model_validator(mode="after")
    def unique_names(self) -> EvaluationManifest:
        names = [case.name for case in self.cases]
        if len(names) != len(set(names)):
            raise ValueError("evaluation case names must be unique")
        return self


@dataclass(frozen=True)
class EvaluationCase:
    spec: EvaluationCaseSpec
    repair_case: RepairCaseV2


def _validate_expected_capability(
    spec: EvaluationCaseSpec,
    repair_case: RepairCaseV2,
) -> None:
    expected = spec.expected
    if isinstance(expected, ExpectedNoRepair):
        return

    case_value = repair_case.model_dump(mode="json", by_alias=True)
    capabilities = {
        capability["capability_id"]: capability for capability in case_value["capabilities"]
    }
    capability = capabilities.get(expected.capability_id)
    if capability is None:
        raise EvaluationDataError(f"evaluation case {spec.name} expects an unavailable capability")
    if capability["action"] != expected.action:
        raise EvaluationDataError(
            f"evaluation case {spec.name} expects the wrong capability action"
        )

    if isinstance(expected, ExpectedManualImport):
        if capability["file_id"] != expected.file_id:
            raise EvaluationDataError(
                f"evaluation case {spec.name} expects the wrong manual-import file"
            )
        return

    if isinstance(expected, (ExpectedRemuxBluray, ExpectedRemuxDVD)):
        return

    candidate_ids = set(capability["candidate_file_ids"])
    if len(set(expected.ordered_file_ids)) != len(expected.ordered_file_ids) or not set(
        expected.ordered_file_ids
    ).issubset(candidate_ids):
        raise EvaluationDataError(f"evaluation case {spec.name} expects unavailable join files")


class CommonEvaluationSettings(StrictModel):
    model: str
    output_tokens: int
    timeout_seconds: float
    runs: int
    case: EvaluationName | None = None


class OllamaEvaluationSettings(CommonEvaluationSettings):
    backend: Literal["ollama"] = "ollama"
    context_tokens: int
    reasoning: bool


class OpenRouterEvaluationSettings(CommonEvaluationSettings):
    backend: Literal["openrouter"] = "openrouter"
    provider: str
    reasoning_effort: ReasoningEffort


EvaluationSettings = Annotated[
    OllamaEvaluationSettings | OpenRouterEvaluationSettings,
    Field(discriminator="backend"),
]


class EvaluationResult(StrictModel):
    case_name: str
    run: int
    attempts: int
    attempt_errors: list[str]
    used_fallback: bool
    passed: bool
    violations: list[str]
    decision: dict[str, JsonValue]


class EvaluationReport(StrictModel):
    schema_version: Literal["radarr-repair-evaluation-report/v1"] = (
        "radarr-repair-evaluation-report/v1"
    )
    settings: EvaluationSettings
    passed: bool
    results: list[EvaluationResult]


def _decode_pointer_token(token: str) -> str:
    return token.replace("~1", "/").replace("~0", "~")


def _replace_pointer(value: JsonValue, pointer: str, replacement: JsonValue) -> None:
    if not pointer.startswith("/"):
        raise EvaluationDataError(f"replacement path is not an absolute JSON pointer: {pointer}")
    tokens = [_decode_pointer_token(token) for token in pointer[1:].split("/")]
    current: Any = value
    for token in tokens[:-1]:
        try:
            current = current[int(token)] if isinstance(current, list) else current[token]
        except (IndexError, KeyError, TypeError, ValueError) as error:
            raise EvaluationDataError(f"replacement path does not exist: {pointer}") from error
    final = tokens[-1]
    try:
        if isinstance(current, list):
            current[int(final)] = deepcopy(replacement)
        else:
            if final not in current:
                raise KeyError(final)
            current[final] = deepcopy(replacement)
    except (IndexError, KeyError, TypeError, ValueError) as error:
        raise EvaluationDataError(f"replacement path does not exist: {pointer}") from error


def load_evaluation_cases() -> list[EvaluationCase]:
    root = files(__package__).joinpath("evaluations", "v2")
    manifest = EvaluationManifest.model_validate_json(
        root.joinpath("manifest.json").read_text(encoding="utf-8")
    )
    result: list[EvaluationCase] = []
    for spec in manifest.cases:
        base_payload = root.joinpath("cases", spec.base_case).read_text(encoding="utf-8")
        value: JsonValue = json.loads(base_payload)
        for pointer, replacement in spec.replacements.items():
            _replace_pointer(value, pointer, replacement)
        repair_case = decode_case(json.dumps(value, allow_nan=False).encode())
        _validate_expected_capability(spec, repair_case)
        result.append(EvaluationCase(spec=spec, repair_case=repair_case))
    return result


def _expectation_violations(
    expected: ExpectedDecision,
    decision_value: dict[str, Any],
) -> list[str]:
    violations: list[str] = []
    action = decision_value["action"]

    if action != expected.action:
        violations.append(f"expected {expected.action}, received {action}")
    elif isinstance(expected, ExpectedNoRepair):
        allowed_reasons = {reason.value for reason in expected.allowed_reasons}
        if decision_value["reason"] not in allowed_reasons:
            violations.append("no-repair reason is not allowed by the evaluation case")
    elif isinstance(expected, ExpectedJoin):
        if decision_value["capability_id"] != expected.capability_id:
            violations.append("join selected the wrong capability")
        if decision_value["ordered_file_ids"] != expected.ordered_file_ids:
            violations.append("join selected the wrong files or order")
    elif isinstance(expected, ExpectedManualImport):
        if decision_value["capability_id"] != expected.capability_id:
            violations.append("manual import selected the wrong capability")
        if decision_value["file_id"] != expected.file_id:
            violations.append("manual import selected the wrong file")
    elif isinstance(expected, ExpectedRemuxBluray) and (
        decision_value["capability_id"] != expected.capability_id
    ):
        violations.append("Blu-ray remux selected the wrong playlist")
    elif isinstance(expected, ExpectedRemuxDVD) and (
        decision_value["capability_id"] != expected.capability_id
    ):
        violations.append("DVD remux selected the wrong title")
    return violations


def _semantic_violations(
    evaluation_case: EvaluationCase,
    outcome: PlanningOutcome[RepairDecisionV2],
) -> list[str]:
    decision_value = json.loads(encode_decision(outcome.decision))
    violations = ["planner exhausted its attempts"] if outcome.used_fallback else []
    violations.extend(
        describe_violation(violation)
        for violation in validate_decision_for_case(
            evaluation_case.repair_case,
            outcome.decision,
        )
    )
    violations.extend(_expectation_violations(evaluation_case.spec.expected, decision_value))
    return violations


def evaluate_outcome(
    evaluation_case: EvaluationCase,
    run: int,
    outcome: PlanningOutcome[RepairDecisionV2],
) -> EvaluationResult:
    decision_value = json.loads(encode_decision(outcome.decision))
    violations = _semantic_violations(evaluation_case, outcome)
    return EvaluationResult(
        case_name=evaluation_case.spec.name,
        run=run,
        attempts=outcome.attempts,
        attempt_errors=list(outcome.attempt_errors),
        used_fallback=outcome.used_fallback,
        passed=not violations,
        violations=violations,
        decision=decision_value,
    )


async def run_evaluation(
    planner: Planner,
    settings: EvaluationSettings,
) -> EvaluationReport:
    results: list[EvaluationResult] = []
    evaluation_cases = load_evaluation_cases()
    if settings.case is not None:
        evaluation_cases = [
            evaluation_case
            for evaluation_case in evaluation_cases
            if evaluation_case.spec.name == settings.case
        ]
        if not evaluation_cases:
            raise EvaluationDataError(f"unknown evaluation case: {settings.case}")
    for evaluation_case in evaluation_cases:
        for run in range(1, settings.runs + 1):
            outcome = await planner.plan_with_outcome(evaluation_case.repair_case)
            results.append(evaluate_outcome(evaluation_case, run, outcome))
    return EvaluationReport(
        settings=settings,
        passed=all(result.passed for result in results),
        results=results,
    )
