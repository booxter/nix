from __future__ import annotations

import math
import ssl
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlsplit

from ollama import AsyncClient, ChatResponse
from pydantic import BaseModel

from .decision_validation_core import DecisionViolation
from .planning_core import DecisionModelError
from .structured_decision import diagnostic, structured_prompt
from .structured_model import StructuredModelResponse
from .tracing import MetadataValue, ModelTrace, TraceSink

MODEL_NAME = "qwen3.8:27b-mtp-q4_K_M"
TRACE_METADATA_FIELDS = (
    "done_reason",
    "total_duration",
    "load_duration",
    "prompt_eval_count",
    "prompt_eval_duration",
    "eval_count",
    "eval_duration",
)


class OllamaConfigurationError(ValueError):
    """The Ollama connection or inference settings are unsafe or incomplete."""


@dataclass(frozen=True)
class OllamaSettings:
    base_url: str
    ca_file: Path | None
    client_cert_file: Path | None
    client_key_file: Path | None
    context_tokens: int
    output_tokens: int
    reasoning: bool
    timeout_seconds: float
    model: str = MODEL_NAME
    api_key_file: Path | None = None

    def __post_init__(self) -> None:
        parsed_url = urlsplit(self.base_url)
        if parsed_url.scheme != "https" or parsed_url.hostname is None:
            raise OllamaConfigurationError("Ollama base URL must be an absolute HTTPS URL")
        if parsed_url.username is not None or parsed_url.password is not None:
            raise OllamaConfigurationError("Ollama base URL must not contain credentials")
        has_client_cert = self.client_cert_file is not None
        has_client_key = self.client_key_file is not None
        if has_client_cert != has_client_key:
            raise OllamaConfigurationError(
                "Ollama client certificate and key must be configured together"
            )
        if self.api_key_file is not None and has_client_cert:
            raise OllamaConfigurationError("Ollama bearer and mTLS authentication are exclusive")
        if self.api_key_file is None and not has_client_cert:
            raise OllamaConfigurationError("Ollama authentication must be configured")
        if not self.model or self.model != self.model.strip():
            raise OllamaConfigurationError("Ollama model name must be non-empty and trimmed")
        if self.context_tokens <= 0:
            raise OllamaConfigurationError("Ollama context token limit must be positive")
        if self.output_tokens <= 0 or self.output_tokens > self.context_tokens:
            raise OllamaConfigurationError(
                "Ollama output token limit must be positive and no larger than its context"
            )
        if not math.isfinite(self.timeout_seconds) or self.timeout_seconds <= 0:
            raise OllamaConfigurationError("Ollama timeout must be finite and positive")


@dataclass(frozen=True)
class ChatRequest:
    model: str
    messages: tuple[dict[str, str], ...]
    schema: dict[str, Any]
    context_tokens: int
    output_tokens: int
    reasoning: bool


class ChatClient(Protocol):
    async def complete(self, request: ChatRequest) -> object: ...

    async def close(self) -> None: ...


class NativeChatClient:
    def __init__(self, client: AsyncClient) -> None:
        self._client = client

    async def complete(self, request: ChatRequest) -> object:
        return await self._client.chat(
            model=request.model,
            messages=request.messages,
            stream=False,
            think=request.reasoning,
            format=request.schema,
            options={
                "num_ctx": request.context_tokens,
                "num_predict": request.output_tokens,
                "temperature": 0.0,
            },
        )

    async def close(self) -> None:
        await self._client.close()  # type: ignore[no-untyped-call]


def _tls_context(settings: OllamaSettings) -> ssl.SSLContext:
    try:
        context = ssl.create_default_context(cafile=settings.ca_file)
        if settings.client_cert_file is not None and settings.client_key_file is not None:
            context.load_cert_chain(
                certfile=settings.client_cert_file,
                keyfile=settings.client_key_file,
            )
    except (OSError, ssl.SSLError) as error:
        raise OllamaConfigurationError("failed to load Ollama TLS credentials") from error
    return context


def _api_key(path: Path) -> str:
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise OllamaConfigurationError("failed to load Ollama API key") from error
    value = raw.rstrip("\r\n")
    if not value or value != value.strip() or "\r" in value or "\n" in value:
        raise OllamaConfigurationError("Ollama API key must be non-empty and trimmed")
    return value


class OllamaDecisionModel:
    def __init__(
        self,
        client: ChatClient,
        settings: OllamaSettings,
        trace_sink: TraceSink | None = None,
    ) -> None:
        self._client = client
        self._settings = settings
        self._trace_sink = trace_sink

    @classmethod
    def from_settings(
        cls,
        settings: OllamaSettings,
        trace_sink: TraceSink | None = None,
    ) -> OllamaDecisionModel:
        client_kwargs: dict[str, Any] = {
            "timeout": settings.timeout_seconds,
            "trust_env": False,
            "verify": _tls_context(settings),
            "follow_redirects": False,
        }
        if settings.api_key_file is not None:
            client_kwargs["headers"] = {
                "Authorization": "Bearer " + _api_key(settings.api_key_file)
            }
        client = NativeChatClient(AsyncClient(host=settings.base_url, **client_kwargs))
        return cls(client, settings, trace_sink)

    @staticmethod
    def _raw_fields(
        raw: object,
    ) -> tuple[str | None, str | None, dict[str, MetadataValue]]:
        if not isinstance(raw, ChatResponse):
            return None, None, {}
        raw_output = raw.message.content if isinstance(raw.message.content, str) else None
        reasoning = raw.message.thinking if isinstance(raw.message.thinking, str) else None
        metadata: dict[str, MetadataValue] = {}
        for key in TRACE_METADATA_FIELDS:
            value = getattr(raw, key, None)
            if value is not None and isinstance(value, str | int | float | bool):
                metadata[key] = value
        return raw_output, reasoning, metadata

    async def close(self) -> None:
        await self._client.close()

    def _trace(
        self,
        case_id: str,
        raw: object,
        error: str | None,
    ) -> None:
        if self._trace_sink is None:
            return
        raw_output, reasoning, response_metadata = self._raw_fields(raw)
        self._trace_sink.record(
            ModelTrace(
                case_id=case_id,
                raw_output=raw_output,
                reasoning=reasoning,
                response_metadata=response_metadata,
                error=error,
            )
        )

    async def _generate(
        self,
        system_instruction: str,
        case_content: str,
        schema: dict[str, Any],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> tuple[str, ChatResponse]:
        system_content, case_content = structured_prompt(
            system_instruction,
            case_content,
            correction,
        )
        request = ChatRequest(
            model=self._settings.model,
            messages=(
                {"role": "system", "content": system_content},
                {"role": "user", "content": case_content},
            ),
            schema=schema,
            context_tokens=self._settings.context_tokens,
            output_tokens=self._settings.output_tokens,
            reasoning=self._settings.reasoning,
        )
        try:
            result = await self._client.complete(request)
        # Transport and Ollama protocol failures are retryable. Parsing and
        # contract failures below remain visible to the correction attempt.
        except Exception as error:
            detail = diagnostic(error)
            self._trace(case_id, None, "request failed: " + detail)
            raise DecisionModelError(
                "Ollama request or structured decoding failed: " + detail
            ) from error
        if not isinstance(result, ChatResponse):
            self._trace(case_id, None, "Ollama response was not a chat response")
            raise DecisionModelError("Ollama response was not a chat response")
        raw = result
        if not isinstance(raw.message.content, str):
            self._trace(case_id, raw, "structured output was not text")
            raise DecisionModelError("Ollama structured output was not text")
        return raw.message.content, raw

    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> StructuredModelResponse:
        del decision_model
        decision_output, raw = await self._generate(
            system_instruction,
            case_content,
            decision_schema,
            case_id,
            correction,
        )
        return StructuredModelResponse(
            decision_output,
            "Ollama",
            lambda error: self._trace(case_id, raw, error),
        )
