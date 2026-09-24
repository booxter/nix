from __future__ import annotations

import sys
from collections.abc import Sequence
from typing import NoReturn

from .evaluation import (
    EvaluationReport,
    load_evaluation_cases,
    run_evaluation,
)
from .evaluation_runtime import (
    EvaluationArguments,
    EvaluationSettings,
    evaluation_parser,
    run_model_evaluation,
    write_report,
)
from .model_runtime import (
    ModelFactory,
    RuntimeDecisionModel,
    create_model,
)
from .planning import Planner


class Arguments(EvaluationArguments):
    pass


async def _evaluate(
    model: RuntimeDecisionModel,
    settings: EvaluationSettings,
) -> EvaluationReport:
    return await run_evaluation(Planner(model), settings)


def main(
    argv: Sequence[str] | None = None,
    model_factory: ModelFactory = create_model,
) -> int:
    arguments = evaluation_parser("media-repair-planner-evaluate-radarr").parse_args(
        argv, namespace=Arguments()
    )
    try:
        cases = load_evaluation_cases()
        report = run_model_evaluation(
            arguments,
            model_factory,
            {item.repair_case.case_id.root: item.spec.name for item in cases},
            _evaluate,
        )
        write_report(report, arguments.output)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0 if report.passed else 1


def entrypoint() -> NoReturn:
    raise SystemExit(main())
