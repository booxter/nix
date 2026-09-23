from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import NoReturn

from .evaluation_runtime import (
    EvaluationArguments,
    EvaluationSettings,
    evaluation_parser,
    run_model_evaluation,
    write_report,
)
from .lidarr_evaluation import (
    CorpusCase,
    EvaluationReport,
    load_cases,
    run_evaluation,
)
from .lidarr_planning import LidarrPlanner
from .model_runtime import (
    ModelFactory,
    RuntimeDecisionModel,
    create_model,
)


class Arguments(EvaluationArguments):
    case_directory: Path


def parser() -> argparse.ArgumentParser:
    result = evaluation_parser("media-repair-planner-evaluate-lidarr")
    result.add_argument("--case-directory", required=True, type=Path)
    return result


async def _evaluate(
    model: RuntimeDecisionModel,
    settings: EvaluationSettings,
    corpus: list[CorpusCase],
) -> EvaluationReport:
    return await run_evaluation(LidarrPlanner(model), settings, corpus)


def main(
    argv: Sequence[str] | None = None,
    model_factory: ModelFactory = create_model,
) -> int:
    arguments = parser().parse_args(argv, namespace=Arguments())
    try:
        corpus = load_cases(arguments.case_directory)
        report = run_model_evaluation(
            arguments,
            model_factory,
            {item.repair_case.case_id.root: item.name for item in corpus},
            lambda model, settings: _evaluate(model, settings, corpus),
        )
        write_report(report, arguments.output)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0 if report.passed else 1


def entrypoint() -> NoReturn:
    raise SystemExit(main())
