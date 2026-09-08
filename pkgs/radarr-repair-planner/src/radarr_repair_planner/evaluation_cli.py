from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import NoReturn

from .evaluation import (
    EvaluationReport,
    EvaluationSettings,
    load_evaluation_cases,
    run_evaluation,
)
from .ollama_model import MODEL_NAME, OllamaDecisionModel, OllamaSettings
from .planning import DecisionModel, PlanningGraph
from .tracing import JsonlTraceWriter, TraceSink

ModelFactory = Callable[[OllamaSettings, TraceSink | None], DecisionModel]


class Arguments(argparse.Namespace):
    ollama_url: str
    ca_file: Path
    client_cert_file: Path
    client_key_file: Path
    context_tokens: int
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
    result.add_argument("--ollama-url", required=True)
    result.add_argument("--ca-file", required=True, type=Path)
    result.add_argument("--client-cert-file", required=True, type=Path)
    result.add_argument("--client-key-file", required=True, type=Path)
    result.add_argument("--context-tokens", required=True, type=int)
    result.add_argument("--output-tokens", required=True, type=int)
    result.add_argument(
        "--reasoning",
        choices=("enabled", "disabled"),
        required=True,
    )
    result.add_argument("--timeout-seconds", required=True, type=float)
    result.add_argument("--runs", default=1, type=_bounded_runs)
    result.add_argument("--case", dest="case_name")
    result.add_argument("--trace-output", type=Path)
    result.add_argument("--output", required=True, help="Report path, or - for standard output")
    return result


async def _evaluate(arguments: Arguments, model_factory: ModelFactory) -> EvaluationReport:
    reasoning = arguments.reasoning == "enabled"
    ollama_settings = OllamaSettings(
        base_url=arguments.ollama_url,
        ca_file=arguments.ca_file,
        client_cert_file=arguments.client_cert_file,
        client_key_file=arguments.client_key_file,
        context_tokens=arguments.context_tokens,
        output_tokens=arguments.output_tokens,
        reasoning=reasoning,
        timeout_seconds=arguments.timeout_seconds,
    )
    evaluation_settings = EvaluationSettings(
        model=MODEL_NAME,
        context_tokens=arguments.context_tokens,
        output_tokens=arguments.output_tokens,
        reasoning=reasoning,
        timeout_seconds=arguments.timeout_seconds,
        runs=arguments.runs,
        case=arguments.case_name,
    )
    trace_writer: JsonlTraceWriter | None = None
    try:
        if arguments.trace_output is not None:
            trace_writer = JsonlTraceWriter(
                arguments.trace_output,
                {
                    evaluation_case.repair_case.case_id.root: evaluation_case.spec.name
                    for evaluation_case in load_evaluation_cases()
                },
            )
        return await run_evaluation(
            PlanningGraph(model_factory(ollama_settings, trace_writer)),
            evaluation_settings,
        )
    finally:
        if trace_writer is not None:
            trace_writer.close()


def main(
    argv: Sequence[str] | None = None,
    model_factory: ModelFactory = OllamaDecisionModel.from_settings,
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
