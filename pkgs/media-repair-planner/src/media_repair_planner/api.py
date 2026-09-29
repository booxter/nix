from __future__ import annotations

import asyncio
import json
import re
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict

from .case_models import RepairCaseV3
from .contracts import (
    ContractError,
    decode_case,
    decode_decision,
    encode_decision,
)
from .decision_models import RepairDecisionV3

# Keep the API bound aligned with the controller's maximum JSON document size.
MAX_REQUEST_BYTES = 8 << 20
PLANNING_TIMEOUT_SECONDS = 600.0
MAXIMUM_GUIDANCE_LENGTH = 2_000
MAXIMUM_RUNTIME_DIFFERENCE_MS = 60 * 60 * 1_000
FINGERPRINT_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")


@dataclass(frozen=True)
class PolicyOverrides:
    maximum_runtime_difference_ms: int


class Planner(Protocol):
    async def plan(self, repair_case: RepairCaseV3) -> RepairDecisionV3: ...

    async def reconsider(
        self,
        repair_case: RepairCaseV3,
        prior_decision: RepairDecisionV3,
        request_id: str,
        guidance: str,
        policy_overrides: PolicyOverrides | None,
    ) -> RepairDecisionV3: ...


class TypedPlanner[CaseT, DecisionT](Protocol):
    async def plan(self, repair_case: CaseT) -> DecisionT: ...


class TypedReconsideringPlanner[CaseT, DecisionT](TypedPlanner[CaseT, DecisionT], Protocol):
    async def reconsider(
        self,
        repair_case: CaseT,
        prior_decision: DecisionT,
        request_id: str,
        guidance: str,
        policy_overrides: PolicyOverrides | None,
    ) -> DecisionT: ...


class PreparedPlan(Protocol):
    async def execute(self) -> bytes: ...


class PlanningEndpoint(Protocol):
    def prepare(self, payload: bytes) -> PreparedPlan: ...


@dataclass(frozen=True)
class ContractPlan[CaseT, DecisionT]:
    repair_case: CaseT
    planner: TypedPlanner[CaseT, DecisionT]
    encode_decision: Callable[[DecisionT], bytes]

    async def execute(self) -> bytes:
        return self.encode_decision(await self.planner.plan(self.repair_case))


@dataclass(frozen=True)
class ContractEndpoint[CaseT, DecisionT]:
    planner: TypedPlanner[CaseT, DecisionT]
    decode_case: Callable[[bytes], CaseT]
    encode_decision: Callable[[DecisionT], bytes]

    def prepare(self, payload: bytes) -> PreparedPlan:
        return ContractPlan(
            repair_case=self.decode_case(payload),
            planner=self.planner,
            encode_decision=self.encode_decision,
        )


@dataclass(frozen=True)
class ReconsiderationPlan[CaseT, DecisionT]:
    repair_case: CaseT
    prior_decision: DecisionT
    request_id: str
    guidance: str
    policy_overrides: PolicyOverrides | None
    planner: TypedReconsideringPlanner[CaseT, DecisionT]
    encode_decision: Callable[[DecisionT], bytes]

    async def execute(self) -> bytes:
        decision = await self.planner.reconsider(
            self.repair_case,
            self.prior_decision,
            self.request_id,
            self.guidance,
            self.policy_overrides,
        )
        return self.encode_decision(decision)


@dataclass(frozen=True)
class ReconsiderationEndpoint[CaseT, DecisionT]:
    planner: TypedReconsideringPlanner[CaseT, DecisionT]
    decode_case: Callable[[bytes], CaseT]
    decode_decision: Callable[[bytes], DecisionT]
    encode_decision: Callable[[DecisionT], bytes]
    case_id: Callable[[CaseT], str]
    decision_case_id: Callable[[DecisionT], str]

    def prepare(self, payload: bytes) -> PreparedPlan:
        try:
            value = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ContractError("invalid reconsideration request") from error
        if not isinstance(value, dict) or set(value) != {
            "repair_case",
            "prior_decision",
            "operator_guidance",
        }:
            raise ContractError("invalid reconsideration request")
        guidance = value["operator_guidance"]
        if (
            not isinstance(guidance, dict)
            or not {"request_id", "text"}.issubset(guidance)
            or not set(guidance).issubset({"request_id", "text", "policy_overrides"})
        ):
            raise ContractError("invalid reconsideration guidance")
        request_id = guidance["request_id"]
        text = guidance["text"]
        policy_overrides = _decode_policy_overrides(guidance.get("policy_overrides"))
        if (
            not isinstance(request_id, str)
            or FINGERPRINT_PATTERN.fullmatch(request_id) is None
            or not isinstance(text, str)
            or text != text.strip()
            or len(text.encode()) > MAXIMUM_GUIDANCE_LENGTH
            or any(ord(character) < 32 and character not in "\n\t" for character in text)
            or (not text and policy_overrides is None)
        ):
            raise ContractError("invalid reconsideration guidance")
        try:
            repair_case = self.decode_case(json.dumps(value["repair_case"]).encode())
            prior_decision = self.decode_decision(json.dumps(value["prior_decision"]).encode())
        except (TypeError, ValueError) as error:
            raise ContractError("invalid reconsideration request") from error
        if self.decision_case_id(prior_decision) != self.case_id(repair_case):
            raise ContractError("prior decision does not match the repair case")
        return ReconsiderationPlan(
            repair_case=repair_case,
            prior_decision=prior_decision,
            request_id=request_id,
            guidance=text,
            policy_overrides=policy_overrides,
            planner=self.planner,
            encode_decision=self.encode_decision,
        )


def _decode_policy_overrides(value: object) -> PolicyOverrides | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"maximum_runtime_difference_ms"}:
        raise ContractError("invalid reconsideration policy overrides")
    maximum = value["maximum_runtime_difference_ms"]
    if (
        not isinstance(maximum, int)
        or isinstance(maximum, bool)
        or maximum <= 0
        or maximum > MAXIMUM_RUNTIME_DIFFERENCE_MS
    ):
        raise ContractError("invalid reconsideration policy overrides")
    return PolicyOverrides(maximum_runtime_difference_ms=maximum)


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


def _planning_endpoints(
    planner: Planner,
    additional_endpoints: Mapping[str, PlanningEndpoint] | None = None,
) -> dict[str, PlanningEndpoint]:
    endpoints: dict[str, PlanningEndpoint] = {
        "/v3/repair-plans": ContractEndpoint(
            planner=planner,
            decode_case=decode_case,
            encode_decision=encode_decision,
        ),
        "/v3/reconsiderations": ReconsiderationEndpoint(
            planner=planner,
            decode_case=decode_case,
            decode_decision=decode_decision,
            encode_decision=encode_decision,
            case_id=lambda repair_case: repair_case.case_id.root,
            decision_case_id=lambda decision: decision.root.case_id.root,
        ),
    }
    if additional_endpoints is not None:
        overlap = endpoints.keys() & additional_endpoints.keys()
        if overlap:
            raise ValueError(f"duplicate planning endpoint: {min(overlap)}")
        endpoints.update(additional_endpoints)
    return endpoints


def create_app(
    planner: Planner,
    limits: ApiLimits | None = None,
    additional_endpoints: Mapping[str, PlanningEndpoint] | None = None,
) -> FastAPI:
    endpoints = _planning_endpoints(planner, additional_endpoints)

    limits = limits if limits is not None else ApiLimits()
    app = FastAPI(
        title="Media repair planner",
        docs_url=None,
        openapi_url=None,
        redoc_url=None,
    )
    generation_lock = asyncio.Lock()

    @app.get("/ready")
    async def ready() -> dict[str, str]:
        return {"status": "ready"}

    async def plan(endpoint: PlanningEndpoint, request: Request) -> Response:
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
            prepared = endpoint.prepare(body)
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
                    encoded = await prepared.execute()
        except TimeoutError:
            return _error(504, ErrorCode.PLANNING_TIMEOUT, "Plan generation timed out.")
        # This service boundary must not expose provider failures or model output.
        except Exception:  # noqa: BLE001
            return _error(500, ErrorCode.PLANNING_FAILED, "Plan generation failed.")

        return Response(content=encoded, media_type="application/json")

    def planning_route(endpoint: PlanningEndpoint) -> Callable[[Request], Awaitable[Response]]:
        async def route(request: Request) -> Response:
            return await plan(endpoint, request)

        return route

    for path, endpoint in endpoints.items():
        app.add_api_route(path, planning_route(endpoint), methods=["POST"])

    return app
