from __future__ import annotations

import argparse
from collections.abc import Callable
from pathlib import Path
from typing import Protocol, runtime_checkable

from .openrouter_model import (
    REASONING_EFFORTS,
    OpenRouterDecisionModel,
    OpenRouterSettings,
    ReasoningEffort,
)
from .structured_model import StructuredDecisionModel
from .tracing import TraceSink

ModelFactory = Callable[[OpenRouterSettings, TraceSink | None], StructuredDecisionModel]


class ModelArguments(argparse.Namespace):
    model: str
    openrouter_api_key_file: Path
    openrouter_provider: str
    output_tokens: int
    reasoning: ReasoningEffort
    timeout_seconds: float


@runtime_checkable
class CloseableDecisionModel(Protocol):
    async def close(self) -> None: ...


def add_model_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model", required=True)
    parser.add_argument("--openrouter-api-key-file", required=True, type=Path)
    parser.add_argument("--openrouter-provider", required=True)
    parser.add_argument("--output-tokens", required=True, type=int)
    parser.add_argument("--reasoning", choices=REASONING_EFFORTS, required=True)
    parser.add_argument("--timeout-seconds", required=True, type=float)


def settings_from_arguments(arguments: ModelArguments) -> OpenRouterSettings:
    return OpenRouterSettings(
        api_key_file=arguments.openrouter_api_key_file,
        model=arguments.model,
        provider=arguments.openrouter_provider,
        output_tokens=arguments.output_tokens,
        reasoning_effort=arguments.reasoning,
        timeout_seconds=arguments.timeout_seconds,
    )


def create_model(
    settings: OpenRouterSettings,
    trace_sink: TraceSink | None,
) -> StructuredDecisionModel:
    return OpenRouterDecisionModel.from_settings(settings, trace_sink)


async def close_model(model: StructuredDecisionModel | None) -> None:
    if isinstance(model, CloseableDecisionModel):
        await model.close()
