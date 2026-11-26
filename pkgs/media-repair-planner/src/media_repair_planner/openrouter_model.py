from __future__ import annotations

import asyncio
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol

from openai import APIStatusError, AsyncOpenAI, DefaultAsyncHttpxClient
from openai.types.chat import ChatCompletionMessageParam
from pydantic import BaseModel

from .decision_validation_core import DecisionViolation
from .openai_structured_output import (
    OpenAIStructuredOutputError,
    decision_envelope_model,
    unwrap_openai_decision,
)
from .openrouter_usage import response_metadata
from .planning_core import DecisionModelError, DecisionModelUnavailable
from .structured_decision import diagnostic, structured_prompt
from .structured_model import StructuredModelResponse
from .tracing import MetadataValue, ModelTrace, TraceSink

OPENROUTER_API_URL = "https://openrouter.ai/api/v1"
ReasoningEffort = Literal[
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
]
REASONING_EFFORTS: tuple[ReasoningEffort, ...] = (
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
)


class OpenRouterConfigurationError(ValueError):
    """The OpenRouter connection or inference settings are invalid."""


@dataclass(frozen=True)
class OpenRouterSettings:
    api_key_file: Path
    model: str
    provider: str
    output_tokens: int
    reasoning_effort: ReasoningEffort
    timeout_seconds: float

    def __post_init__(self) -> None:
        if not self.model or self.model != self.model.strip() or "/" not in self.model:
            raise OpenRouterConfigurationError(
                "OpenRouter model must be a provider-qualified model ID"
            )
        if not self.provider or self.provider != self.provider.strip():
            raise OpenRouterConfigurationError("OpenRouter provider must be non-empty and trimmed")
        if self.output_tokens <= 0:
            raise OpenRouterConfigurationError("OpenRouter output token limit must be positive")
        if self.reasoning_effort not in REASONING_EFFORTS:
            raise OpenRouterConfigurationError("OpenRouter reasoning effort is unsupported")
        if not math.isfinite(self.timeout_seconds) or self.timeout_seconds <= 0:
            raise OpenRouterConfigurationError("OpenRouter timeout must be finite and positive")


@dataclass(frozen=True)
class OpenRouterRequest:
    model: str
    provider: str
    output_tokens: int
    reasoning_effort: ReasoningEffort
    system_content: str
    case_content: str
    decision_model: type[BaseModel]


@dataclass(frozen=True)
class OpenRouterResponse:
    content: str | None
    refused: bool
    metadata: dict[str, MetadataValue]


class OpenRouterResponseError(Exception):
    def __init__(self, cause: Exception, metadata: dict[str, MetadataValue]) -> None:
        super().__init__(str(cause))
        self.cause = cause
        self.metadata = metadata


class OpenRouterTransport(Protocol):
    async def complete(self, request: OpenRouterRequest) -> OpenRouterResponse: ...

    async def close(self) -> None: ...


def _api_key(path: Path) -> str:
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise OpenRouterConfigurationError("failed to load OpenRouter API key") from error
    value = raw.rstrip("\r\n")
    if not value or value != value.strip() or "\r" in value or "\n" in value:
        raise OpenRouterConfigurationError("OpenRouter API key must be non-empty and trimmed")
    return value


class OpenRouterChatTransport:
    """Narrow OpenRouter boundary implemented with the maintained OpenAI SDK."""

    def __init__(
        self,
        api_key: str,
        timeout_seconds: float,
        base_url: str = OPENROUTER_API_URL,
    ) -> None:
        self._client = AsyncOpenAI(
            api_key=api_key,
            base_url=base_url,
            http_client=DefaultAsyncHttpxClient(trust_env=False),
            max_retries=0,
            timeout=timeout_seconds,
        )

    async def complete(self, request: OpenRouterRequest) -> OpenRouterResponse:
        messages: list[ChatCompletionMessageParam] = [
            {"role": "system", "content": request.system_content},
            {"role": "user", "content": request.case_content},
        ]
        response = await self._client.chat.completions.with_raw_response.parse(
            messages=messages,
            model=request.model,
            max_tokens=request.output_tokens,
            response_format=decision_envelope_model(request.decision_model),
            store=False,
            extra_body={
                "provider": {
                    "only": [request.provider],
                    "allow_fallbacks": False,
                    "require_parameters": True,
                    "data_collection": "deny",
                },
                "reasoning": {
                    "effort": request.reasoning_effort,
                    "exclude": True,
                },
            },
        )
        # Capture billing before the SDK validates structured output. Truncated
        # or malformed decisions can still consume paid tokens.
        metadata = response_metadata(response.content, response.request_id)
        try:
            completion = response.parse()
            if len(completion.choices) != 1:
                raise ValueError("OpenRouter returned an unexpected number of choices")
        except Exception as error:
            metadata["error_type"] = type(error).__name__
            raise OpenRouterResponseError(error, metadata) from error
        choice = completion.choices[0]
        return OpenRouterResponse(
            content=choice.message.content,
            refused=choice.message.refusal is not None,
            metadata=metadata,
        )

    async def close(self) -> None:
        await self._client.close()


class OpenRouterDecisionModel:
    def __init__(
        self,
        transport: OpenRouterTransport,
        settings: OpenRouterSettings,
        trace_sink: TraceSink | None = None,
    ) -> None:
        self._transport = transport
        self._settings = settings
        self._trace_sink = trace_sink

    @classmethod
    def from_settings(
        cls,
        settings: OpenRouterSettings,
        trace_sink: TraceSink | None = None,
    ) -> OpenRouterDecisionModel:
        transport = OpenRouterChatTransport(
            api_key=_api_key(settings.api_key_file),
            timeout_seconds=settings.timeout_seconds,
        )
        return cls(transport, settings, trace_sink)

    async def close(self) -> None:
        await self._transport.close()

    def _trace(
        self,
        case_id: str,
        response: OpenRouterResponse | None,
        error: str | None,
    ) -> None:
        if self._trace_sink is None:
            return
        self._trace_sink.record(
            ModelTrace(
                case_id=case_id,
                raw_output=None if response is None else response.content,
                reasoning=None,
                response_metadata={} if response is None else response.metadata,
                error=error,
            )
        )

    async def _generate(
        self,
        system_instruction: str,
        case_content: str,
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> tuple[str, OpenRouterResponse]:
        system_content, case_content = structured_prompt(
            system_instruction,
            case_content,
            correction,
        )
        request = OpenRouterRequest(
            model=self._settings.model,
            provider=self._settings.provider,
            output_tokens=self._settings.output_tokens,
            reasoning_effort=self._settings.reasoning_effort,
            system_content=system_content,
            case_content=case_content,
            decision_model=decision_model,
        )
        try:
            response = await self._transport.complete(request)
        except asyncio.CancelledError:
            self._trace(case_id, None, "request cancelled")
            raise
        except OpenRouterResponseError as error:
            detail = diagnostic(error.cause)
            self._trace(
                case_id,
                OpenRouterResponse(None, False, error.metadata),
                "request failed: " + detail,
            )
            raise DecisionModelUnavailable("OpenRouter request failed: " + detail) from error
        except Exception as error:
            detail = diagnostic(error)
            metadata: dict[str, MetadataValue] = {"error_type": type(error).__name__}
            if isinstance(error, APIStatusError):
                metadata.update(request_id=error.request_id, http_status=error.status_code)
            self._trace(
                case_id,
                OpenRouterResponse(None, False, metadata),
                "request failed: " + detail,
            )
            raise DecisionModelUnavailable("OpenRouter request failed: " + detail) from error
        if response.content is None:
            detail = (
                "OpenRouter refused to return a decision"
                if response.refused
                else "OpenRouter response did not contain text"
            )
            self._trace(case_id, response, detail)
            raise DecisionModelError(detail)
        try:
            decision_output = unwrap_openai_decision(response.content)
        except OpenAIStructuredOutputError as error:
            self._trace(case_id, response, str(error))
            raise DecisionModelError("OpenRouter " + str(error)) from error
        return decision_output, response

    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> StructuredModelResponse:
        del decision_schema
        decision_output, response = await self._generate(
            system_instruction,
            case_content,
            decision_model,
            case_id,
            correction,
        )
        return StructuredModelResponse(
            decision_output,
            "OpenRouter",
            lambda error: self._trace(case_id, response, error),
        )
