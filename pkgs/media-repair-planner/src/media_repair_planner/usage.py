from __future__ import annotations

import json
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TextIO
from uuid import uuid4

from .tracing import ModelTrace


@dataclass(frozen=True)
class RequestAttribution:
    service: str | None = None
    job_id: int | None = None


_attribution: ContextVar[RequestAttribution | None] = ContextVar(
    "model_request_attribution", default=None
)


@contextmanager
def attribute_requests(service: str, job_id: int | None) -> Iterator[None]:
    token = _attribution.set(RequestAttribution(service, job_id))
    try:
        yield
    finally:
        _attribution.reset(token)


@dataclass
class JsonlUsageWriter:
    stream: TextIO
    model: str
    provider: str

    def record(self, trace: ModelTrace) -> None:
        attribution = _attribution.get() or RequestAttribution()
        # Production accounting contains no prompts, decisions, or exception
        # messages: provider parse errors can embed private response content.
        value = {
            "event": "model_request",
            "timestamp": datetime.now(UTC).isoformat(),
            "attempt_id": uuid4().hex,
            "service": attribution.service,
            "job_id": attribution.job_id,
            "case_id": trace.case_id,
            "outcome": "succeeded" if trace.error is None else "failed",
            "model": self.model,
            "provider": self.provider,
            **trace.response_metadata,
        }
        self.stream.write(json.dumps(value, allow_nan=False) + "\n")
        self.stream.flush()
