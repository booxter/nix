from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator
from pathlib import Path

import httpx
import pytest
from radarr_repair_planner.api import ApiLimits, Planner, create_app
from radarr_repair_planner.case_models import RepairCaseV3
from radarr_repair_planner.contracts import decode_decision
from radarr_repair_planner.decision_models import RepairDecisionV3

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v3/examples"
CASE_BYTES = (FIXTURES / "repair-case-joinable.json").read_bytes()
DECISION = decode_decision((FIXTURES / "repair-decision-join.json").read_bytes())


class StaticPlanner:
    def __init__(self, decision: RepairDecisionV3 = DECISION) -> None:
        self.decision = decision
        self.cases: list[RepairCaseV3] = []

    async def plan(self, repair_case: RepairCaseV3) -> RepairDecisionV3:
        self.cases.append(repair_case)
        return self.decision


class BlockingPlanner:
    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.release = asyncio.Event()

    async def plan(self, repair_case: RepairCaseV3) -> RepairDecisionV3:
        self.started.set()
        await self.release.wait()
        return DECISION


class FailingPlanner:
    async def plan(self, repair_case: RepairCaseV3) -> RepairDecisionV3:
        raise RuntimeError("private model failure")


def client_for(planner: Planner) -> httpx.AsyncClient:
    transport = httpx.ASGITransport(app=create_app(planner))
    return httpx.AsyncClient(transport=transport, base_url="http://planner")


async def test_readiness_does_not_call_planner() -> None:
    planner = StaticPlanner()
    async with client_for(planner) as client:
        response = await client.get("/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert planner.cases == []


async def test_plans_a_valid_case() -> None:
    planner = StaticPlanner()
    async with client_for(planner) as client:
        response = await client.post(
            "/v3/repair-plans",
            content=CASE_BYTES,
            headers={"Content-Type": "application/json; charset=utf-8"},
        )

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json"
    assert decode_decision(response.content) == DECISION
    assert len(planner.cases) == 1


async def test_rejects_wrong_media_type_before_planning() -> None:
    planner = StaticPlanner()
    async with client_for(planner) as client:
        response = await client.post(
            "/v3/repair-plans",
            content=CASE_BYTES,
            headers={"Content-Type": "text/plain"},
        )

    assert response.status_code == 415
    assert response.json() == {
        "code": "unsupported_media_type",
        "message": "Content-Type must be application/json.",
    }
    assert planner.cases == []


async def test_rejects_invalid_contract_without_echoing_input() -> None:
    planner = StaticPlanner()
    async with client_for(planner) as client:
        response = await client.post(
            "/v3/repair-plans",
            content=b'{"private":"do not echo"}',
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 422
    assert response.json()["code"] == "invalid_request"
    assert "do not echo" not in response.text
    assert planner.cases == []


async def test_rejects_body_over_content_length_limit() -> None:
    planner = StaticPlanner()
    app = create_app(planner, ApiLimits(max_request_bytes=len(CASE_BYTES) - 1))
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://planner") as client:
        response = await client.post(
            "/v3/repair-plans",
            content=CASE_BYTES,
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 413
    assert response.json()["code"] == "request_too_large"
    assert planner.cases == []


async def test_rejects_streamed_body_over_limit() -> None:
    async def oversized_body() -> AsyncIterator[bytes]:
        yield b"{"
        yield b"x" * len(CASE_BYTES)

    planner = StaticPlanner()
    app = create_app(planner, ApiLimits(max_request_bytes=len(CASE_BYTES) - 1))
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://planner") as client:
        response = await client.post(
            "/v3/repair-plans",
            content=oversized_body(),
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 413
    assert response.json()["code"] == "request_too_large"
    assert planner.cases == []


async def test_allows_only_one_generation_at_a_time() -> None:
    planner = BlockingPlanner()
    async with client_for(planner) as client:
        first = asyncio.create_task(
            client.post(
                "/v3/repair-plans",
                content=CASE_BYTES,
                headers={"Content-Type": "application/json"},
            )
        )
        await planner.started.wait()

        second = await client.post(
            "/v3/repair-plans",
            content=CASE_BYTES,
            headers={"Content-Type": "application/json"},
        )
        planner.release.set()
        first_response = await first

    assert first_response.status_code == 200
    assert second.status_code == 429
    assert second.json()["code"] == "planner_busy"


async def test_times_out_generation() -> None:
    planner = BlockingPlanner()
    app = create_app(planner, ApiLimits(planning_timeout_seconds=0.01))
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://planner") as client:
        response = await client.post(
            "/v3/repair-plans",
            content=CASE_BYTES,
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 504
    assert response.json()["code"] == "planning_timeout"


async def test_hides_unexpected_planner_failure() -> None:
    async with client_for(FailingPlanner()) as client:
        response = await client.post(
            "/v3/repair-plans",
            content=CASE_BYTES,
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 500
    assert response.json()["code"] == "planning_failed"
    assert "private model failure" not in response.text


def test_limits_must_be_positive() -> None:
    for limits in (
        {"max_request_bytes": 0},
        {"planning_timeout_seconds": 0},
    ):
        with pytest.raises(ValueError, match="must be positive"):
            ApiLimits(**limits)
