from __future__ import annotations

import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Queue
from threading import Thread
from typing import Any

import pytest
from radarr_repair_planner.case_models import RepairCaseV1
from radarr_repair_planner.contracts import decision_schema, decode_case, encode_case
from radarr_repair_planner.decision_validation import (
    DecisionViolation,
    ViolationCode,
    format_correction,
)
from radarr_repair_planner.openrouter_model import (
    SCHEMA_NAME,
    OpenRouterChatTransport,
    OpenRouterConfigurationError,
    OpenRouterDecisionModel,
    OpenRouterRequest,
    OpenRouterResponse,
    OpenRouterSettings,
)
from radarr_repair_planner.planning import DecisionModelError
from radarr_repair_planner.structured_decision import SCHEMA_INSTRUCTION
from radarr_repair_planner.tracing import JsonlTraceWriter

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v1/examples"


def repair_case() -> RepairCaseV1:
    return decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())


def decision_value() -> dict[str, Any]:
    value = json.loads((FIXTURES / "repair-decision-join.json").read_bytes())
    assert isinstance(value, dict)
    return value


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
    def __init__(self, result: OpenRouterResponse | Exception) -> None:
        self.result = result
        self.requests: list[OpenRouterRequest] = []
        self.closed = False

    async def complete(self, request: OpenRouterRequest) -> OpenRouterResponse:
        self.requests.append(request)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result

    async def close(self) -> None:
        self.closed = True


async def test_decision_model_sends_pinned_structured_request() -> None:
    response = OpenRouterResponse(
        content=json.dumps(decision_value()),
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

    result = await model.decide(
        "system instruction",
        case,
        correction,
    )

    assert result.root.case_id.root == case.case_id.root
    request = transport.requests[0]
    assert request.model == "openai/gpt-5.6-terra"
    assert request.provider == "openai"
    assert request.output_tokens == 4096
    assert request.reasoning_effort == "medium"
    prefix = "system instruction\n\n" + SCHEMA_INSTRUCTION
    schema_text, separator, correction_text = request.system_content.removeprefix(prefix).partition(
        "\n\n"
    )
    assert json.loads(schema_text) == decision_schema()
    assert separator == "\n\n"
    assert correction_text == format_correction(correction)
    assert request.case_content == encode_case(case).decode()

    await model.close()

    assert transport.closed


async def test_decision_model_wraps_transport_failure() -> None:
    model = OpenRouterDecisionModel(
        ScriptedTransport(RuntimeError("transport failed")),
        settings(),
    )

    with pytest.raises(
        DecisionModelError,
        match=r"OpenRouter request failed: RuntimeError: transport failed",
    ):
        await model.decide("system instruction", repair_case())


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
            OpenRouterResponse("[]", False, {}),
            "output was not an object",
            ViolationCode.NON_OBJECT_JSON,
        ),
        (
            OpenRouterResponse("not JSON", False, {}),
            "decoding failed",
            ViolationCode.INVALID_JSON,
        ),
        (
            OpenRouterResponse("{}", False, {}),
            "decision contract failed",
            ViolationCode.MISSING_FIELD,
        ),
        (
            OpenRouterResponse(
                '{"action":"no_repair"}{"action":"no_repair"}',
                False,
                {},
            ),
            "decoding failed",
            ViolationCode.EXTRA_OUTPUT,
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
        await model.decide("system instruction", repair_case())

    assert tuple(violation.code for violation in raised.value.violations) == (
        () if violation_code is None else (violation_code,)
    )


async def test_decision_model_traces_response_without_reasoning(tmp_path: Path) -> None:
    path = tmp_path / "trace.jsonl"
    case = repair_case()
    raw_output = json.dumps(decision_value())
    response = OpenRouterResponse(
        content=raw_output,
        refused=False,
        metadata={
            "provider": "OpenAI",
            "completion_tokens": 100,
            "reasoning_tokens": 80,
        },
    )

    with JsonlTraceWriter(path, {case.case_id.root: "clear_ordered_join"}) as trace:
        await OpenRouterDecisionModel(
            ScriptedTransport(response),
            settings(),
            trace,
        ).decide("system instruction", case)

    value = json.loads(path.read_text())
    assert value["raw_output"] == raw_output
    assert value["reasoning"] is None
    assert value["response_metadata"] == response.metadata
    assert value["error"] is None


class RecordingOpenRouterServer(ThreadingHTTPServer):
    requests: Queue[dict[str, Any]]


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
                    "finish_reason": "stop",
                    "message": {
                        "role": "assistant",
                        "content": json.dumps(decision_value()),
                    },
                }
            ],
            "usage": {
                "prompt_tokens": 1000,
                "completion_tokens": 120,
                "total_tokens": 1120,
                "completion_tokens_details": {"reasoning_tokens": 80},
            },
        }
        payload = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextmanager
def openrouter_server() -> Iterator[tuple[str, Queue[dict[str, Any]]]]:
    requests: Queue[dict[str, Any]] = Queue()
    server = RecordingOpenRouterServer(("localhost", 0), OpenRouterHandler)
    server.requests = requests
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
    assert value == {
        "messages": [
            {"role": "system", "content": "system instruction"},
            {"role": "user", "content": "case JSON"},
        ],
        "model": "openai/gpt-5.6-terra",
        "max_completion_tokens": 4096,
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": SCHEMA_NAME,
                "schema": decision_schema(),
                "strict": True,
            },
        },
        "store": False,
        "stream": False,
        "provider": {
            "only": ["openai"],
            "allow_fallbacks": False,
            "require_parameters": True,
            "data_collection": "deny",
        },
        "reasoning": {"effort": "medium", "exclude": True},
        "test_path": "/v1/chat/completions",
        "test_authorization": "Bearer router-secret",
    }
    assert response.content == json.dumps(decision_value())
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
    }


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
