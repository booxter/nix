from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

from .model_runtime import (
    BackendSettings,
    ModelArguments,
    ModelFactory,
    RuntimeDecisionModel,
    add_model_arguments,
    close_model,
    settings_from_arguments,
)
from .ollama_model import OllamaSettings
from .openrouter_model import ReasoningEffort
from .tracing import JsonlTraceWriter


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CommonEvaluationSettings(StrictModel):
    model: str
    output_tokens: int
    timeout_seconds: float
    runs: int
    case: str | None = None


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


class EvaluationArguments(ModelArguments):
    runs: int
    case_name: str | None
    trace_output: Path | None
    output: str


def _bounded_runs(value: str) -> int:
    result = int(value)
    if result < 1 or result > 10:
        raise argparse.ArgumentTypeError("runs must be between 1 and 10")
    return result


def evaluation_parser(program: str) -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog=program)
    add_model_arguments(result)
    result.add_argument("--runs", default=1, type=_bounded_runs)
    result.add_argument("--case", dest="case_name")
    result.add_argument("--trace-output", type=Path)
    result.add_argument("--output", required=True, help="Report path, or - for standard output")
    return result


def evaluation_settings(
    settings: BackendSettings,
    arguments: EvaluationArguments,
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


async def _evaluate_with_model[ReportT: BaseModel](
    arguments: EvaluationArguments,
    model_factory: ModelFactory,
    case_names: dict[str, str],
    evaluate: Callable[[RuntimeDecisionModel, EvaluationSettings], Awaitable[ReportT]],
) -> ReportT:
    backend_settings = settings_from_arguments(arguments)
    settings = evaluation_settings(backend_settings, arguments)
    trace_writer: JsonlTraceWriter | None = None
    model: RuntimeDecisionModel | None = None
    try:
        if arguments.trace_output is not None:
            trace_writer = JsonlTraceWriter(arguments.trace_output, case_names)
        model = model_factory(backend_settings, trace_writer)
        return await evaluate(model, settings)
    finally:
        try:
            await close_model(model)
        finally:
            if trace_writer is not None:
                trace_writer.close()


def run_model_evaluation[ReportT: BaseModel](
    arguments: EvaluationArguments,
    model_factory: ModelFactory,
    case_names: dict[str, str],
    evaluate: Callable[[RuntimeDecisionModel, EvaluationSettings], Awaitable[ReportT]],
) -> ReportT:
    return asyncio.run(_evaluate_with_model(arguments, model_factory, case_names, evaluate))


def write_report(report: BaseModel, output: str) -> None:
    payload = (report.model_dump_json(indent=2) + "\n").encode()
    if output == "-":
        sys.stdout.buffer.write(payload)
    else:
        Path(output).write_bytes(payload)
