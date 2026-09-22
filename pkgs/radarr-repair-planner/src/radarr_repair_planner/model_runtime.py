from __future__ import annotations

import argparse
from collections.abc import Callable
from pathlib import Path
from typing import Protocol, runtime_checkable

from .ollama_model import MODEL_NAME, OllamaDecisionModel, OllamaSettings
from .openrouter_model import (
    REASONING_EFFORTS,
    OpenRouterDecisionModel,
    OpenRouterSettings,
    ReasoningEffort,
)
from .planning import DecisionModel
from .structured_model import StructuredDecisionModel
from .tracing import TraceSink

BackendSettings = OllamaSettings | OpenRouterSettings


class RuntimeDecisionModel(DecisionModel, StructuredDecisionModel, Protocol):
    pass


ModelFactory = Callable[[BackendSettings, TraceSink | None], RuntimeDecisionModel]


class ModelArguments(argparse.Namespace):
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


@runtime_checkable
class CloseableDecisionModel(Protocol):
    async def close(self) -> None: ...


def add_model_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--backend", choices=("ollama", "openrouter"), default="ollama")
    parser.add_argument("--model")
    parser.add_argument("--ollama-url")
    parser.add_argument("--ca-file", type=Path)
    parser.add_argument("--client-cert-file", type=Path)
    parser.add_argument("--client-key-file", type=Path)
    parser.add_argument("--ollama-api-key-file", type=Path)
    parser.add_argument("--openrouter-api-key-file", type=Path)
    parser.add_argument("--openrouter-provider")
    parser.add_argument("--context-tokens", type=int)
    parser.add_argument("--output-tokens", required=True, type=int)
    parser.add_argument(
        "--reasoning",
        choices=("enabled", "disabled", *REASONING_EFFORTS),
        required=True,
        help="enabled/disabled for Ollama; an effort level for OpenRouter",
    )
    parser.add_argument("--timeout-seconds", required=True, type=float)


def _reject_options(arguments: ModelArguments, names: tuple[str, ...], backend: str) -> None:
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


def _ollama_settings(arguments: ModelArguments) -> OllamaSettings:
    _reject_options(
        arguments,
        ("openrouter-api-key-file", "openrouter-provider"),
        "ollama",
    )
    if arguments.reasoning not in ("enabled", "disabled"):
        raise ValueError("--reasoning must be enabled or disabled with --backend ollama")
    return OllamaSettings(
        base_url=_require(arguments.ollama_url, "--ollama-url", "ollama"),
        ca_file=arguments.ca_file,
        client_cert_file=arguments.client_cert_file,
        client_key_file=arguments.client_key_file,
        api_key_file=arguments.ollama_api_key_file,
        context_tokens=_require(arguments.context_tokens, "--context-tokens", "ollama"),
        output_tokens=arguments.output_tokens,
        reasoning=arguments.reasoning == "enabled",
        timeout_seconds=arguments.timeout_seconds,
        model=arguments.model or MODEL_NAME,
    )


def _openrouter_settings(arguments: ModelArguments) -> OpenRouterSettings:
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
    reasoning_effort: ReasoningEffort = arguments.reasoning
    return OpenRouterSettings(
        api_key_file=_require(
            arguments.openrouter_api_key_file,
            "--openrouter-api-key-file",
            "openrouter",
        ),
        model=_require(arguments.model, "--model", "openrouter"),
        provider=_require(
            arguments.openrouter_provider,
            "--openrouter-provider",
            "openrouter",
        ),
        output_tokens=arguments.output_tokens,
        reasoning_effort=reasoning_effort,
        timeout_seconds=arguments.timeout_seconds,
    )


def settings_from_arguments(arguments: ModelArguments) -> BackendSettings:
    if arguments.backend == "ollama":
        return _ollama_settings(arguments)
    if arguments.backend == "openrouter":
        return _openrouter_settings(arguments)
    raise AssertionError(f"unsupported backend parsed: {arguments.backend}")


def create_model(
    settings: BackendSettings,
    trace_sink: TraceSink | None,
) -> RuntimeDecisionModel:
    if isinstance(settings, OllamaSettings):
        return OllamaDecisionModel.from_settings(settings, trace_sink)
    return OpenRouterDecisionModel.from_settings(settings, trace_sink)


async def close_model(model: RuntimeDecisionModel | None) -> None:
    if isinstance(model, CloseableDecisionModel):
        await model.close()
