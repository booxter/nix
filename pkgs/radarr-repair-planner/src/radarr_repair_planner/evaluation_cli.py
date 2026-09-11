from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import NoReturn, Protocol, runtime_checkable

from .evaluation import (
    EvaluationReport,
    EvaluationSettings,
    OllamaEvaluationSettings,
    OpenRouterEvaluationSettings,
    load_evaluation_cases,
    run_evaluation,
)
from .ollama_model import MODEL_NAME, OllamaDecisionModel, OllamaSettings
from .openrouter_model import (
    REASONING_EFFORTS,
    OpenRouterDecisionModel,
    OpenRouterSettings,
    ReasoningEffort,
)
from .planning import DecisionModel, PlanningGraph
from .tracing import JsonlTraceWriter, TraceSink

BackendSettings = OllamaSettings | OpenRouterSettings
ModelFactory = Callable[[BackendSettings, TraceSink | None], DecisionModel]


@runtime_checkable
class CloseableDecisionModel(Protocol):
    async def close(self) -> None: ...


class Arguments(argparse.Namespace):
    backend: str
    ollama_url: str | None
    model: str | None
    ca_file: Path | None
    client_cert_file: Path | None
    client_key_file: Path | None
    ollama_api_key_file: Path | None
    openrouter_api_key_file: Path | None
    openrouter_provider: str | None
    context_tokens: int | None
    output_tokens: int
    reasoning: str
    timeout_seconds: float
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
    result.add_argument("--backend", choices=("ollama", "openrouter"), default="ollama")
    result.add_argument("--model")
    result.add_argument("--ollama-url")
    result.add_argument("--ca-file", type=Path)
    result.add_argument("--client-cert-file", type=Path)
    result.add_argument("--client-key-file", type=Path)
    result.add_argument("--ollama-api-key-file", type=Path)
    result.add_argument("--openrouter-api-key-file", type=Path)
    result.add_argument("--openrouter-provider")
    result.add_argument("--context-tokens", type=int)
    result.add_argument("--output-tokens", required=True, type=int)
    result.add_argument(
        "--reasoning",
        choices=("enabled", "disabled", *REASONING_EFFORTS),
        required=True,
        help="enabled/disabled for Ollama; an effort level for OpenRouter",
    )
    result.add_argument("--timeout-seconds", required=True, type=float)
    result.add_argument("--runs", default=1, type=_bounded_runs)
    result.add_argument("--case", dest="case_name")
    result.add_argument("--trace-output", type=Path)
    result.add_argument("--output", required=True, help="Report path, or - for standard output")
    return result


def _reject_options(arguments: Arguments, names: tuple[str, ...], backend: str) -> None:
    supplied = [name for name in names if getattr(arguments, name.replace("-", "_")) is not None]
    if supplied:
        options = ", ".join(f"--{name}" for name in supplied)
        raise ValueError(f"{options} cannot be used with --backend {backend}")


def _require[RequiredValue](
    value: RequiredValue | None,
    option: str,
    backend: str,
) -> RequiredValue:
    if value is None:
        raise ValueError(f"{option} is required with --backend {backend}")
    return value


def _ollama_configuration(
    arguments: Arguments,
) -> tuple[OllamaSettings, OllamaEvaluationSettings]:
    _reject_options(
        arguments,
        ("openrouter-api-key-file", "openrouter-provider"),
        "ollama",
    )
    if arguments.reasoning not in ("enabled", "disabled"):
        raise ValueError("--reasoning must be enabled or disabled with --backend ollama")
    model = arguments.model or MODEL_NAME
    base_url = _require(arguments.ollama_url, "--ollama-url", "ollama")
    context_tokens = _require(arguments.context_tokens, "--context-tokens", "ollama")
    reasoning = arguments.reasoning == "enabled"
    connection = OllamaSettings(
        base_url=base_url,
        ca_file=arguments.ca_file,
        client_cert_file=arguments.client_cert_file,
        client_key_file=arguments.client_key_file,
        api_key_file=arguments.ollama_api_key_file,
        context_tokens=context_tokens,
        output_tokens=arguments.output_tokens,
        reasoning=reasoning,
        timeout_seconds=arguments.timeout_seconds,
        model=model,
    )
    report = OllamaEvaluationSettings(
        model=model,
        context_tokens=context_tokens,
        output_tokens=arguments.output_tokens,
        reasoning=reasoning,
        timeout_seconds=arguments.timeout_seconds,
        runs=arguments.runs,
        case=arguments.case_name,
    )
    return connection, report


def _openrouter_configuration(
    arguments: Arguments,
) -> tuple[OpenRouterSettings, OpenRouterEvaluationSettings]:
    _reject_options(
        arguments,
        (
            "ollama-url",
            "ca-file",
            "client-cert-file",
            "client-key-file",
            "ollama-api-key-file",
            "context-tokens",
        ),
        "openrouter",
    )
    if arguments.reasoning not in REASONING_EFFORTS:
        raise ValueError("--reasoning must be an effort level with --backend openrouter")
    model = _require(arguments.model, "--model", "openrouter")
    provider = _require(arguments.openrouter_provider, "--openrouter-provider", "openrouter")
    api_key_file = _require(
        arguments.openrouter_api_key_file,
        "--openrouter-api-key-file",
        "openrouter",
    )
    reasoning_effort: ReasoningEffort = arguments.reasoning
    connection = OpenRouterSettings(
        api_key_file=api_key_file,
        model=model,
        provider=provider,
        output_tokens=arguments.output_tokens,
        reasoning_effort=reasoning_effort,
        timeout_seconds=arguments.timeout_seconds,
    )
    report = OpenRouterEvaluationSettings(
        model=model,
        provider=provider,
        output_tokens=arguments.output_tokens,
        reasoning_effort=reasoning_effort,
        timeout_seconds=arguments.timeout_seconds,
        runs=arguments.runs,
        case=arguments.case_name,
    )
    return connection, report


def _configuration(arguments: Arguments) -> tuple[BackendSettings, EvaluationSettings]:
    if arguments.backend == "ollama":
        return _ollama_configuration(arguments)
    if arguments.backend == "openrouter":
        return _openrouter_configuration(arguments)
    raise AssertionError(f"unsupported backend parsed: {arguments.backend}")


def _model(settings: BackendSettings, trace_sink: TraceSink | None) -> DecisionModel:
    if isinstance(settings, OllamaSettings):
        return OllamaDecisionModel.from_settings(settings, trace_sink)
    return OpenRouterDecisionModel.from_settings(settings, trace_sink)


async def _evaluate(arguments: Arguments, model_factory: ModelFactory) -> EvaluationReport:
    backend_settings, evaluation_settings = _configuration(arguments)
    trace_writer: JsonlTraceWriter | None = None
    model: DecisionModel | None = None
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
        return await run_evaluation(PlanningGraph(model), evaluation_settings)
    finally:
        try:
            if isinstance(model, CloseableDecisionModel):
                await model.close()
        finally:
            if trace_writer is not None:
                trace_writer.close()


def main(
    argv: Sequence[str] | None = None,
    model_factory: ModelFactory = _model,
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
