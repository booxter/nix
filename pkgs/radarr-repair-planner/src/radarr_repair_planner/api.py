from __future__ import annotations

import asyncio
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict

from .case_models import RepairCaseV2
from .contracts import ContractError, decode_case, encode_decision
from .decision_models import RepairDecisionV2

# Keep the API bound aligned with the controller's maximum JSON document size.
MAX_REQUEST_BYTES = 8 << 20
PLANNING_TIMEOUT_SECONDS = 600.0


class Planner(Protocol):
    async def plan(self, repair_case: RepairCaseV2) -> RepairDecisionV2: ...


class ErrorCode(StrEnum):
    INVALID_REQUEST = "invalid_request"
    PLANNER_BUSY = "planner_busy"
    PLANNING_FAILED = "planning_failed"
    PLANNING_TIMEOUT = "planning_timeout"
    REQUEST_TOO_LARGE = "request_too_large"
    UNSUPPORTED_MEDIA_TYPE = "unsupported_media_type"


class ErrorResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    code: ErrorCode
    message: str


@dataclass(frozen=True)
class ApiLimits:
    max_request_bytes: int = MAX_REQUEST_BYTES
    planning_timeout_seconds: float = PLANNING_TIMEOUT_SECONDS

    def __post_init__(self) -> None:
        if self.max_request_bytes < 1:
            raise ValueError("max_request_bytes must be positive")
        if self.planning_timeout_seconds <= 0:
            raise ValueError("planning_timeout_seconds must be positive")


class RequestTooLarge(Exception):
    pass


def _error(status_code: int, code: ErrorCode, message: str) -> JSONResponse:
    body = ErrorResponse(code=code, message=message)
    return JSONResponse(status_code=status_code, content=body.model_dump(mode="json"))


def _content_length(request: Request) -> int | None:
    value = request.headers.get("content-length")
    if value is None:
        return None
    try:
        length = int(value)
    except ValueError:
        return -1
    return length


async def _read_body(request: Request, maximum: int) -> bytes:
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > maximum:
            raise RequestTooLarge
        body.extend(chunk)
    return bytes(body)


def create_app(planner: Planner, limits: ApiLimits | None = None) -> FastAPI:
    limits = limits if limits is not None else ApiLimits()
    app = FastAPI(
        title="Radarr repair planner",
        docs_url=None,
        openapi_url=None,
        redoc_url=None,
    )
    generation_lock = asyncio.Lock()

    @app.get("/ready")
    async def ready() -> dict[str, str]:
        return {"status": "ready"}

    @app.post("/v2/repair-plans")
    async def plan(request: Request) -> Response:
        media_type = request.headers.get("content-type", "").partition(";")[0].strip().lower()
        if media_type != "application/json":
            return _error(
                415,
                ErrorCode.UNSUPPORTED_MEDIA_TYPE,
                "Content-Type must be application/json.",
            )

        content_length = _content_length(request)
        if content_length is not None and content_length < 0:
            return _error(400, ErrorCode.INVALID_REQUEST, "Content-Length is invalid.")
        if content_length is not None and content_length > limits.max_request_bytes:
            return _error(413, ErrorCode.REQUEST_TOO_LARGE, "Request body is too large.")

        try:
            body = await _read_body(request, limits.max_request_bytes)
        except RequestTooLarge:
            return _error(413, ErrorCode.REQUEST_TOO_LARGE, "Request body is too large.")

        try:
            repair_case = decode_case(body)
        except ContractError:
            return _error(
                422,
                ErrorCode.INVALID_REQUEST,
                "Request does not satisfy the repair case contract.",
            )

        if generation_lock.locked():
            return _error(429, ErrorCode.PLANNER_BUSY, "Another plan is being generated.")

        try:
            async with generation_lock:
                async with asyncio.timeout(limits.planning_timeout_seconds):
                    decision = await planner.plan(repair_case)
            encoded = encode_decision(decision)
        except TimeoutError:
            return _error(504, ErrorCode.PLANNING_TIMEOUT, "Plan generation timed out.")
        # This service boundary must not expose provider failures or model output.
        except Exception:  # noqa: BLE001
            return _error(500, ErrorCode.PLANNING_FAILED, "Plan generation failed.")

        return Response(content=encoded, media_type="application/json")

    return app
