from __future__ import annotations

import json
import math
import ssl
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlsplit

from langchain_core.language_models import LanguageModelInput
from langchain_core.messages import BaseMessage, HumanMessage, SystemMessage
from langchain_core.runnables import RunnableConfig
from langchain_ollama import ChatOllama

from .case_models import RepairCaseV1
from .contracts import ContractError, decision_schema, decode_decision, encode_case
from .decision_models import RepairDecisionV1
from .planning import DecisionModelError
from .tracing import MetadataValue, ModelTrace, TraceSink

MODEL_NAME = "qwen3.8:27b-mtp-q4_K_M"
MODEL_ERROR_LIMIT = 384
TRACE_METADATA_FIELDS = (
    "done_reason",
    "total_duration",
    "load_duration",
    "prompt_eval_count",
    "prompt_eval_duration",
    "eval_count",
    "eval_duration",
)
SCHEMA_INSTRUCTION = """\
The authoritative response JSON Schema follows. Return only one JSON object
that validates against it, without Markdown fences or surrounding text.
"""


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


class ChatResponseModel(Protocol):
    async def ainvoke(
        self,
        input: LanguageModelInput,
        config: RunnableConfig | None = None,
        **kwargs: Any,
    ) -> object: ...


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
        response_model: ChatResponseModel,
        trace_sink: TraceSink | None = None,
    ) -> None:
        self._response_model = response_model
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
        }
        if settings.api_key_file is not None:
            client_kwargs["headers"] = {
                "Authorization": "Bearer " + _api_key(settings.api_key_file)
            }
        chat = ChatOllama(
            model=settings.model,
            base_url=settings.base_url,
            client_kwargs=client_kwargs,
            disable_streaming=True,
            num_ctx=settings.context_tokens,
            num_predict=settings.output_tokens,
            reasoning=settings.reasoning,
            temperature=0.0,
            validate_model_on_init=False,
        )
        # Bind the schema without LangChain's include_raw wrapper. That wrapper
        # changes async invocations to streaming, while this boundary needs both
        # an explicit non-streaming request and the raw response on parse failure.
        response_model = chat.bind(format=decision_schema())
        return cls(response_model, trace_sink)

    @staticmethod
    def _diagnostic(error: BaseException) -> str:
        detail = " ".join(str(error).split())
        return (type(error).__name__ + (f": {detail}" if detail else ""))[:MODEL_ERROR_LIMIT]

    @staticmethod
    def _raw_fields(
        raw: object,
    ) -> tuple[str | None, str | None, dict[str, MetadataValue]]:
        if not isinstance(raw, BaseMessage):
            return None, None, {}
        content = raw.content
        raw_output = content if isinstance(content, str) else json.dumps(content, allow_nan=False)
        reasoning_value = raw.additional_kwargs.get("reasoning_content")
        reasoning = reasoning_value if isinstance(reasoning_value, str) else None
        metadata: dict[str, MetadataValue] = {}
        for key in TRACE_METADATA_FIELDS:
            if key not in raw.response_metadata:
                continue
            value = raw.response_metadata.get(key)
            if value is None or isinstance(value, str | int | float | bool):
                metadata[key] = value
        return raw_output, reasoning, metadata

    def _trace(
        self,
        repair_case: RepairCaseV1,
        raw: object,
        error: str | None,
    ) -> None:
        if self._trace_sink is None:
            return
        raw_output, reasoning, response_metadata = self._raw_fields(raw)
        self._trace_sink.record(
            ModelTrace(
                case_id=repair_case.case_id.root,
                raw_output=raw_output,
                reasoning=reasoning,
                response_metadata=response_metadata,
                error=error,
            )
        )

    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
    ) -> RepairDecisionV1:
        schema = json.dumps(
            decision_schema(),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        messages = [
            SystemMessage(content=f"{system_instruction.rstrip()}\n\n{SCHEMA_INSTRUCTION}{schema}"),
            HumanMessage(content=encode_case(repair_case).decode()),
        ]
        try:
            result = await self._response_model.ainvoke(messages, stream=False)
        # The runnable combines HTTP and Ollama protocol failures without a stable
        # common exception type. Failures raised by that boundary are retryable;
        # our parsing and contract validation below remain visible.
        except Exception as error:
            diagnostic = self._diagnostic(error)
            self._trace(repair_case, None, "request failed: " + diagnostic)
            raise DecisionModelError(
                "Ollama request or structured decoding failed: " + diagnostic
            ) from error
        if not isinstance(result, BaseMessage):
            self._trace(repair_case, None, "Ollama response was not a message")
            raise DecisionModelError("Ollama response was not a message")
        raw = result
        if not isinstance(raw.content, str):
            self._trace(repair_case, raw, "structured output was not text")
            raise DecisionModelError("Ollama structured output was not text")
        try:
            result = json.loads(raw.content)
        except json.JSONDecodeError as error:
            diagnostic = self._diagnostic(error)
            self._trace(repair_case, raw, "structured decoding failed: " + diagnostic)
            raise DecisionModelError("Ollama structured decoding failed: " + diagnostic) from error
        if not isinstance(result, dict):
            self._trace(repair_case, raw, "structured output was not an object")
            raise DecisionModelError("Ollama structured output was not an object")
        try:
            payload = json.dumps(result, allow_nan=False).encode()
        except (TypeError, ValueError) as error:
            self._trace(repair_case, raw, "structured output was not JSON")
            raise DecisionModelError("Ollama structured output was not JSON") from error
        try:
            decision = decode_decision(payload)
        except ContractError as error:
            self._trace(repair_case, raw, "decision contract failed: " + self._diagnostic(error))
            raise
        self._trace(repair_case, raw, None)
        return decision
