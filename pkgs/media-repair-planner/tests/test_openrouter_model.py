from __future__ import annotations

import asyncio
import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO
from pathlib import Path
from queue import Queue
from threading import Thread
from typing import Any

import pytest
from media_repair_planner.case_models import RepairCaseV3
from media_repair_planner.contracts import decision_schema, decode_case, decode_decision
from media_repair_planner.decision_models import RepairDecisionV3
from media_repair_planner.decision_validation import validate_decision_object
from media_repair_planner.decision_validation_core import (
    DecisionViolation,
    ViolationCode,
    format_correction,
)
from media_repair_planner.openrouter_model import (
    OpenRouterChatTransport,
    OpenRouterConfigurationError,
    OpenRouterDecisionModel,
    OpenRouterRequest,
    OpenRouterResponse,
    OpenRouterSettings,
)
from media_repair_planner.planning import DecisionModelError, DecisionModelUnavailable
from media_repair_planner.radarr_projection import project_case
from media_repair_planner.structured_model import StructuredDecisionModel
from media_repair_planner.structured_planning import StructuredDecisionGenerator
from media_repair_planner.usage import JsonlUsageWriter, attribute_requests

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v3/examples"


def repair_case() -> RepairCaseV3:
    return decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())


def decision_value() -> dict[str, Any]:
    value = json.loads((FIXTURES / "repair-decision-join.json").read_bytes())
    assert isinstance(value, dict)
    return value


def decision_output(value: object | None = None) -> str:
    return json.dumps({"decision": decision_value() if value is None else value})


def settings(**changes: object) -> OpenRouterSettings:
    values: dict[str, object] = {
        "api_key_file": Path("api-key"),
        "model": "openai/gpt-5.6-terra",
        "provider": "openai",
        "output_tokens": 4096,
        "reasoning_effort": "medium",
        "timeout_seconds": 5,
    }
    values.update(changes)
    return OpenRouterSettings(**values)


class ScriptedTransport:
    def __init__(self, result: OpenRouterResponse | BaseException) -> None:
        self.result = result
        self.requests: list[OpenRouterRequest] = []
        self.closed = False

    async def complete(self, request: OpenRouterRequest) -> OpenRouterResponse:
        self.requests.append(request)
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result

    async def close(self) -> None:
        self.closed = True


async def decide(
    model: StructuredDecisionModel,
    repair_case: RepairCaseV3,
    correction: tuple[DecisionViolation, ...] = (),
) -> RepairDecisionV3:
    generator = StructuredDecisionGenerator(
        model=model,
        system_instruction="system instruction",
        decision_schema=decision_schema,
        decision_model=RepairDecisionV3,
        project_case=project_case,
        decode_decision=decode_decision,
        validate_decision_object=validate_decision_object,
        case_id=lambda value: value.case_id.root,
    )
    return await generator.generate(repair_case, correction)


async def test_decision_model_sends_pinned_structured_request() -> None:
    response = OpenRouterResponse(
        content=decision_output(),
        refused=False,
        metadata={"provider": "OpenAI"},
    )
    transport = ScriptedTransport(response)
    model = OpenRouterDecisionModel(transport, settings())
    case = repair_case()
    correction = (
        DecisionViolation(
            ViolationCode.UNKNOWN_EVIDENCE,
            ("evidence_refs",),
            rejected_values=("download_01",),
            allowed_values=("evidence_queue_01",),
        ),
    )

    result = await decide(model, case, correction)

    assert result.root.case_id.root == case.case_id.root
    request = transport.requests[0]
    assert request.model == "openai/gpt-5.6-terra"
    assert request.provider == "openai"
    assert request.output_tokens == 4096
    assert request.reasoning_effort == "medium"
    projection = project_case(case)
    assert request.system_content == "system instruction\n\n" + format_correction(
        projection.project_correction(correction)
    )
    assert request.case_content == projection.case_content

    await model.close()

    assert transport.closed


async def test_decision_model_wraps_transport_failure() -> None:
    model = OpenRouterDecisionModel(
        ScriptedTransport(RuntimeError("transport failed")),
        settings(),
    )

    with pytest.raises(
        DecisionModelUnavailable,
        match=r"OpenRouter request failed: RuntimeError: transport failed",
    ):
        await decide(model, repair_case())


@pytest.mark.parametrize(
    ("response", "message", "violation_code"),
    [
        (
            OpenRouterResponse(None, False, {}),
            "response did not contain text",
            None,
        ),
        (
            OpenRouterResponse(None, True, {}),
            "refused to return a decision",
            None,
        ),
        (
            OpenRouterResponse(decision_output([]), False, {}),
            "output was not an object",
            ViolationCode.NON_OBJECT_JSON,
        ),
        (
            OpenRouterResponse("not JSON", False, {}),
            "envelope was not valid JSON",
            None,
        ),
        (
            OpenRouterResponse(decision_output({}), False, {}),
            "decision contract failed",
            ViolationCode.MISSING_FIELD,
        ),
        (
            OpenRouterResponse(
                '{"action":"no_repair"}{"action":"no_repair"}',
                False,
                {},
            ),
            "envelope was not valid JSON",
            None,
        ),
    ],
)
async def test_decision_model_rejects_invalid_response(
    response: OpenRouterResponse,
    message: str,
    violation_code: ViolationCode | None,
) -> None:
    model = OpenRouterDecisionModel(ScriptedTransport(response), settings())

    with pytest.raises(DecisionModelError, match=message) as raised:
        await decide(model, repair_case())

    assert tuple(violation.code for violation in raised.value.violations) == (
        () if violation_code is None else (violation_code,)
    )


async def test_decision_model_applies_complete_contract_after_unwrapping() -> None:
    decision = decision_value()
    evidence_refs = decision["evidence_refs"]
    assert isinstance(evidence_refs, list)
    evidence_refs.append(evidence_refs[0])
    model = OpenRouterDecisionModel(
        ScriptedTransport(OpenRouterResponse(decision_output(decision), False, {})),
        settings(),
    )

    with pytest.raises(DecisionModelError, match="decision contract failed"):
        await decide(model, repair_case())


class RecordingOpenRouterServer(ThreadingHTTPServer):
    requests: Queue[dict[str, Any]]
    completion_content: str
    finish_reason: str
    status_code: int


class OpenRouterHandler(BaseHTTPRequestHandler):
    server: RecordingOpenRouterServer

    def do_POST(self) -> None:
        size = int(self.headers["Content-Length"])
        value = json.loads(self.rfile.read(size))
        assert isinstance(value, dict)
        value["test_path"] = self.path
        value["test_authorization"] = self.headers.get("Authorization")
        self.server.requests.put(value)

        response = {
            "id": "generation_01",
            "object": "chat.completion",
            "created": 1789000000,
            "model": "openai/gpt-5.6-terra",
            "provider": "OpenAI",
            "system_fingerprint": "fingerprint_01",
            "choices": [
                {
                    "index": 0,
                    "finish_reason": self.server.finish_reason,
                    "message": {
                        "role": "assistant",
                        "content": self.server.completion_content,
                    },
                }
            ],
            "usage": {
                "prompt_tokens": 1000,
                "completion_tokens": 120,
                "total_tokens": 1120,
                "completion_tokens_details": {"reasoning_tokens": 80},
                "prompt_tokens_details": {"cached_tokens": 600},
                "cost": 0,
                "is_byok": True,
                "cost_details": {
                    "upstream_inference_cost": 0.003,
                    "upstream_inference_prompt_cost": 0.002,
                    "upstream_inference_completions_cost": 0.001,
                },
            },
        }
        payload = json.dumps(response).encode()
        self.send_response(self.server.status_code)
        self.send_header("x-request-id", "request_01")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextmanager
def openrouter_server(
    *, content: str | None = None, finish_reason: str = "stop", status_code: int = 200
) -> Iterator[tuple[str, Queue[dict[str, Any]]]]:
    requests: Queue[dict[str, Any]] = Queue()
    server = RecordingOpenRouterServer(("localhost", 0), OpenRouterHandler)
    server.requests = requests
    server.completion_content = decision_output() if content is None else content
    server.finish_reason = finish_reason
    server.status_code = status_code
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        del host
        yield f"http://localhost:{port}/v1", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


async def test_chat_transport_uses_pinned_private_request() -> None:
    request = OpenRouterRequest(
        model="openai/gpt-5.6-terra",
        provider="openai",
        output_tokens=4096,
        reasoning_effort="medium",
        system_content="system instruction",
        case_content="case JSON",
        decision_model=RepairDecisionV3,
    )
    with openrouter_server() as (base_url, requests):
        transport = OpenRouterChatTransport(
            api_key="router-secret",
            timeout_seconds=5,
            base_url=base_url,
        )
        try:
            response = await transport.complete(request)
        finally:
            await transport.close()

    value = requests.get_nowait()
    response_format = value.pop("response_format")
    assert response_format["type"] == "json_schema"
    assert response_format["json_schema"]["name"] == "RepairDecisionV3Envelope"
    assert response_format["json_schema"]["strict"] is True
    schema = response_format["json_schema"]["schema"]
    assert schema["type"] == "object"
    assert schema["required"] == ["decision"]
    assert value["model"] == request.model
    assert value["max_tokens"] == request.output_tokens
    assert value["store"] is False
    assert value["provider"] == {
        "only": ["openai"],
        "allow_fallbacks": False,
        "require_parameters": True,
        "data_collection": "deny",
    }
    assert value["reasoning"] == {"effort": "medium", "exclude": True}
    assert value["test_authorization"] == "Bearer router-secret"
    assert response.content == decision_output()
    assert response.refused is False
    assert response.metadata == {
        "model": "openai/gpt-5.6-terra",
        "provider": "OpenAI",
        "finish_reason": "stop",
        "system_fingerprint": "fingerprint_01",
        "prompt_tokens": 1000,
        "completion_tokens": 120,
        "reasoning_tokens": 80,
        "total_tokens": 1120,
        "request_id": "request_01",
        "generation_id": "generation_01",
        "cached_tokens": 600,
        "cost": 0,
        "is_byok": True,
        "upstream_inference_cost": 0.003,
        "upstream_inference_prompt_cost": 0.002,
        "upstream_inference_completions_cost": 0.001,
    }


@pytest.mark.parametrize(
    ("content", "finish_reason", "status_code"),
    [
        (None, "stop", 200),
        ("private malformed response", "stop", 200),
        (None, "length", 200),
        (None, "stop", 502),
    ],
)
async def test_production_accounting_keeps_usage_even_when_parsing_fails(
    content: str | None, finish_reason: str, status_code: int
) -> None:
    stream = StringIO()
    with openrouter_server(
        content=content, finish_reason=finish_reason, status_code=status_code
    ) as (
        base_url,
        requests,
    ):
        transport = OpenRouterChatTransport("router-secret", 5, base_url)
        model = OpenRouterDecisionModel(
            transport,
            settings(),
            JsonlUsageWriter(stream, "openai/gpt-5.6-terra", "OpenAI"),
        )
        try:
            with attribute_requests("radarr", 42):
                if content is None and finish_reason == "stop" and status_code == 200:
                    await decide(model, repair_case())
                else:
                    with pytest.raises(DecisionModelUnavailable):
                        await decide(model, repair_case())
        finally:
            await model.close()

    records = [json.loads(line) for line in stream.getvalue().splitlines()]
    assert len(records) == 1
    record = records[0]
    assert record["service"] == "radarr"
    assert record["job_id"] == 42
    assert record["request_id"] == "request_01"
    assert record["outcome"] == (
        "succeeded"
        if content is None and finish_reason == "stop" and status_code == 200
        else "failed"
    )
    if status_code == 200:
        assert record["completion_tokens"] == 120
        assert record["reasoning_tokens"] == 80
        assert record["cached_tokens"] == 600
        assert record["cost"] == 0
        assert record["upstream_inference_cost"] == 0.003
    else:
        assert record["http_status"] == status_code
        assert "completion_tokens" not in record
    assert requests.qsize() == 1
    assert "private malformed response" not in stream.getvalue()
    assert "router-secret" not in stream.getvalue()
    assert "raw_output" not in record


async def test_production_accounting_records_cancelled_requests() -> None:
    stream = StringIO()
    model = OpenRouterDecisionModel(
        ScriptedTransport(asyncio.CancelledError()),
        settings(),
        JsonlUsageWriter(stream, "model", "provider"),
    )
    with pytest.raises(asyncio.CancelledError):
        await decide(model, repair_case())
    record = json.loads(stream.getvalue())
    assert record["outcome"] == "failed"
    assert record["job_id"] is None
    assert record["service"] is None
    assert "cost" not in record


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"model": "gpt-5.6-terra"}, "provider-qualified"),
        ({"model": " openai/gpt-5.6-terra"}, "provider-qualified"),
        ({"provider": ""}, "provider must"),
        ({"provider": " openai"}, "provider must"),
        ({"output_tokens": 0}, "output token"),
        ({"reasoning_effort": "extreme"}, "reasoning effort"),
        ({"timeout_seconds": float("inf")}, "timeout"),
    ],
)
def test_settings_reject_invalid_values(
    changes: dict[str, object],
    message: str,
) -> None:
    with pytest.raises(OpenRouterConfigurationError, match=message):
        settings(**changes)


@pytest.mark.parametrize("value", ["", " secret", "secret ", "secret\nsecond"])
def test_model_rejects_invalid_api_key(tmp_path: Path, value: str) -> None:
    api_key_file = tmp_path / "api-key"
    api_key_file.write_text(value, encoding="utf-8")

    with pytest.raises(
        OpenRouterConfigurationError,
        match="API key must be non-empty and trimmed",
    ):
        OpenRouterDecisionModel.from_settings(settings(api_key_file=api_key_file))


def test_model_rejects_unreadable_api_key(tmp_path: Path) -> None:
    with pytest.raises(
        OpenRouterConfigurationError,
        match="failed to load OpenRouter API key",
    ):
        OpenRouterDecisionModel.from_settings(settings(api_key_file=tmp_path / "missing-api-key"))
