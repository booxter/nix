from __future__ import annotations

import json
import math
import ssl
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlsplit

from langchain_core.language_models import LanguageModelInput
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.runnables import RunnableConfig
from langchain_ollama import ChatOllama

from .case_models import RepairCaseV1
from .contracts import decision_schema, decode_decision, encode_case
from .decision_models import RepairDecisionV1
from .planning import DecisionModelError

MODEL_NAME = "qwen3.8:27b-mtp-q4_K_M"
MODEL_ERROR_LIMIT = 384


class OllamaConfigurationError(ValueError):
    """The Ollama connection or inference settings are unsafe or incomplete."""


@dataclass(frozen=True)
class OllamaSettings:
    base_url: str
    ca_file: Path
    client_cert_file: Path
    client_key_file: Path
    context_tokens: int
    output_tokens: int
    reasoning: bool
    timeout_seconds: float

    def __post_init__(self) -> None:
        parsed_url = urlsplit(self.base_url)
        if parsed_url.scheme != "https" or parsed_url.hostname is None:
            raise OllamaConfigurationError("Ollama base URL must be an absolute HTTPS URL")
        if parsed_url.username is not None or parsed_url.password is not None:
            raise OllamaConfigurationError("Ollama base URL must not contain credentials")
        if self.context_tokens <= 0:
            raise OllamaConfigurationError("Ollama context token limit must be positive")
        if self.output_tokens <= 0 or self.output_tokens > self.context_tokens:
            raise OllamaConfigurationError(
                "Ollama output token limit must be positive and no larger than its context"
            )
        if not math.isfinite(self.timeout_seconds) or self.timeout_seconds <= 0:
            raise OllamaConfigurationError("Ollama timeout must be finite and positive")


class StructuredChatModel(Protocol):
    async def ainvoke(
        self,
        input: LanguageModelInput,
        config: RunnableConfig | None = None,
        **kwargs: Any,
    ) -> object: ...


def _tls_context(settings: OllamaSettings) -> ssl.SSLContext:
    try:
        context = ssl.create_default_context(cafile=settings.ca_file)
        context.load_cert_chain(
            certfile=settings.client_cert_file,
            keyfile=settings.client_key_file,
        )
    except (OSError, ssl.SSLError) as error:
        raise OllamaConfigurationError("failed to load Ollama TLS credentials") from error
    return context


class OllamaDecisionModel:
    def __init__(self, structured_model: StructuredChatModel) -> None:
        self._structured_model = structured_model

    @classmethod
    def from_settings(cls, settings: OllamaSettings) -> OllamaDecisionModel:
        chat = ChatOllama(
            model=MODEL_NAME,
            base_url=settings.base_url,
            client_kwargs={
                "timeout": settings.timeout_seconds,
                "trust_env": False,
                "verify": _tls_context(settings),
            },
            disable_streaming=True,
            num_ctx=settings.context_tokens,
            num_predict=settings.output_tokens,
            reasoning=settings.reasoning,
            temperature=0.0,
            validate_model_on_init=False,
        )
        structured_model = chat.with_structured_output(
            decision_schema(),
            method="json_schema",
            include_raw=False,
        )
        return cls(structured_model)

    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
    ) -> RepairDecisionV1:
        messages = [
            SystemMessage(content=system_instruction),
            HumanMessage(content=encode_case(repair_case).decode()),
        ]
        try:
            result = await self._structured_model.ainvoke(messages, stream=False)
        # The runnable combines HTTP, Ollama protocol, and output-parser failures
        # without a stable common exception type. Failures raised by that boundary
        # are retryable; our serialization and validation below remain visible.
        except Exception as error:
            detail = " ".join(str(error).split())
            diagnostic = type(error).__name__ + (f": {detail}" if detail else "")
            raise DecisionModelError(
                "Ollama request or structured decoding failed: " + diagnostic[:MODEL_ERROR_LIMIT]
            ) from error
        if not isinstance(result, dict):
            raise DecisionModelError("Ollama structured output was not an object")
        try:
            payload = json.dumps(result, allow_nan=False).encode()
        except (TypeError, ValueError) as error:
            raise DecisionModelError("Ollama structured output was not JSON") from error
        return decode_decision(payload)
