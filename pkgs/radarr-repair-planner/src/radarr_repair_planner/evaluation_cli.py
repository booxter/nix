from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import NoReturn

from .evaluation import (
    EvaluationReport,
    EvaluationSettings,
    OllamaEvaluationSettings,
    OpenRouterEvaluationSettings,
    load_evaluation_cases,
    run_evaluation,
)
from .model_runtime import (
    BackendSettings,
    ModelArguments,
    ModelFactory,
    RuntimeDecisionModel,
    add_model_arguments,
    close_model,
    create_model,
    settings_from_arguments,
)
from .ollama_model import OllamaSettings
from .planning import Planner
from .tracing import JsonlTraceWriter


class Arguments(ModelArguments):
    runs: int
    case_name: str | None
    trace_output: Path | None
    output: str


def _bounded_runs(value: str) -> int:
    result = int(value)
    if result < 1 or result > 10:
        raise argparse.ArgumentTypeError("runs must be between 1 and 10")
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="radarr-repair-planner-evaluate")
    add_model_arguments(result)
    result.add_argument("--runs", default=1, type=_bounded_runs)
    result.add_argument("--case", dest="case_name")
    result.add_argument("--trace-output", type=Path)
    result.add_argument("--output", required=True, help="Report path, or - for standard output")
    return result


def _evaluation_settings(
    settings: BackendSettings,
    arguments: Arguments,
) -> EvaluationSettings:
    if isinstance(settings, OllamaSettings):
        return OllamaEvaluationSettings(
            model=settings.model,
            context_tokens=settings.context_tokens,
            output_tokens=settings.output_tokens,
            reasoning=settings.reasoning,
            timeout_seconds=settings.timeout_seconds,
            runs=arguments.runs,
            case=arguments.case_name,
        )
    return OpenRouterEvaluationSettings(
        model=settings.model,
        provider=settings.provider,
        output_tokens=settings.output_tokens,
        reasoning_effort=settings.reasoning_effort,
        timeout_seconds=settings.timeout_seconds,
        runs=arguments.runs,
        case=arguments.case_name,
    )


async def _evaluate(arguments: Arguments, model_factory: ModelFactory) -> EvaluationReport:
    backend_settings = settings_from_arguments(arguments)
    evaluation_settings = _evaluation_settings(backend_settings, arguments)
    trace_writer: JsonlTraceWriter | None = None
    model: RuntimeDecisionModel | None = None
    try:
        if arguments.trace_output is not None:
            trace_writer = JsonlTraceWriter(
                arguments.trace_output,
                {
                    evaluation_case.repair_case.case_id.root: evaluation_case.spec.name
                    for evaluation_case in load_evaluation_cases()
                },
            )
        model = model_factory(backend_settings, trace_writer)
        return await run_evaluation(Planner(model), evaluation_settings)
    finally:
        try:
            await close_model(model)
        finally:
            if trace_writer is not None:
                trace_writer.close()


def main(
    argv: Sequence[str] | None = None,
    model_factory: ModelFactory = create_model,
) -> int:
    arguments = parser().parse_args(argv, namespace=Arguments())
    try:
        report = asyncio.run(_evaluate(arguments, model_factory))
        payload = (report.model_dump_json(indent=2) + "\n").encode()
        if arguments.output == "-":
            sys.stdout.buffer.write(payload)
        else:
            Path(arguments.output).write_bytes(payload)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0 if report.passed else 1


def entrypoint() -> NoReturn:
    raise SystemExit(main())
