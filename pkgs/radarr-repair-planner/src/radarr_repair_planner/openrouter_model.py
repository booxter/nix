from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol, cast

from openai import AsyncOpenAI, DefaultAsyncHttpxClient
from openai.types.chat import ChatCompletionMessageParam
from openai.types.shared_params.response_format_json_schema import (
    ResponseFormatJSONSchema,
)

from .case_models import RepairCaseV1
from .decision_models import RepairDecisionV1
from .decision_validation import DecisionViolation
from .openai_structured_output import (
    SCHEMA_INSTRUCTION,
    OpenAIStructuredOutputError,
    openai_decision_schema,
    unwrap_openai_decision,
)
from .planning import DecisionModelError
from .structured_decision import (
    StructuredDecisionError,
    decision_prompt,
    decode_structured_decision,
    diagnostic,
)
from .tracing import MetadataValue, ModelTrace, TraceSink

OPENROUTER_API_URL = "https://openrouter.ai/api/v1"
SCHEMA_NAME = "radarr_repair_decision_v1"
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


@dataclass(frozen=True)
class OpenRouterResponse:
    content: str | None
    refused: bool
    metadata: dict[str, MetadataValue]


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
        response_format: ResponseFormatJSONSchema = {
            "type": "json_schema",
            "json_schema": {
                "name": SCHEMA_NAME,
                "schema": openai_decision_schema(),
                "strict": True,
            },
        }
        completion = await self._client.chat.completions.create(
            messages=messages,
            model=request.model,
            max_tokens=request.output_tokens,
            response_format=response_format,
            store=False,
            stream=False,
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
        if len(completion.choices) != 1:
            raise ValueError("OpenRouter returned an unexpected number of choices")
        choice = completion.choices[0]
        metadata: dict[str, MetadataValue] = {
            "model": completion.model,
            "finish_reason": choice.finish_reason,
        }
        provider = cast(object, getattr(completion, "provider", None))
        if isinstance(provider, str):
            metadata["provider"] = provider
        if completion.system_fingerprint is not None:
            metadata["system_fingerprint"] = completion.system_fingerprint
        usage = completion.usage
        if usage is not None:
            metadata.update(
                {
                    "prompt_tokens": usage.prompt_tokens,
                    "completion_tokens": usage.completion_tokens,
                    "total_tokens": usage.total_tokens,
                }
            )
            details = usage.completion_tokens_details
            if details is not None and details.reasoning_tokens is not None:
                metadata["reasoning_tokens"] = details.reasoning_tokens
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
        repair_case: RepairCaseV1,
        response: OpenRouterResponse | None,
        error: str | None,
    ) -> None:
        if self._trace_sink is None:
            return
        self._trace_sink.record(
            ModelTrace(
                case_id=repair_case.case_id.root,
                raw_output=None if response is None else response.content,
                reasoning=None,
                response_metadata={} if response is None else response.metadata,
                error=error,
            )
        )

    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> RepairDecisionV1:
        system_content, case_content = decision_prompt(
            system_instruction,
            repair_case,
            correction,
            schema_instruction=SCHEMA_INSTRUCTION,
        )
        request = OpenRouterRequest(
            model=self._settings.model,
            provider=self._settings.provider,
            output_tokens=self._settings.output_tokens,
            reasoning_effort=self._settings.reasoning_effort,
            system_content=system_content,
            case_content=case_content,
        )
        try:
            response = await self._transport.complete(request)
        except Exception as error:
            detail = diagnostic(error)
            self._trace(repair_case, None, "request failed: " + detail)
            raise DecisionModelError("OpenRouter request failed: " + detail) from error
        if response.content is None:
            detail = (
                "OpenRouter refused to return a decision"
                if response.refused
                else "OpenRouter response did not contain text"
            )
            self._trace(repair_case, response, detail)
            raise DecisionModelError(detail)
        try:
            decision_output = unwrap_openai_decision(response.content)
            decision = decode_structured_decision(decision_output)
        except OpenAIStructuredOutputError as error:
            self._trace(repair_case, response, str(error))
            raise DecisionModelError("OpenRouter " + str(error)) from error
        except StructuredDecisionError as error:
            self._trace(repair_case, response, str(error))
            raise DecisionModelError(
                "OpenRouter " + str(error),
                error.violations,
            ) from error
        self._trace(repair_case, response, None)
        return decision
