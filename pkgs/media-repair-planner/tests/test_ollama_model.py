from __future__ import annotations

import json
import os
import ssl
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Queue
from threading import Thread
from typing import Any

import pytest
import trustme
from media_repair_planner.case_models import RepairCaseV3
from media_repair_planner.contracts import (
    decision_schema,
    decode_case,
)
from media_repair_planner.decision_validation_core import (
    DecisionViolation,
    ViolationCode,
    format_correction,
)
from media_repair_planner.ollama_model import (
    MODEL_NAME,
    ChatRequest,
    OllamaConfigurationError,
    OllamaDecisionModel,
    OllamaSettings,
)
from media_repair_planner.planning import DecisionModelError
from media_repair_planner.radarr_projection import project_case
from media_repair_planner.tracing import JsonlTraceWriter, ModelTrace
from ollama import ChatResponse, Message

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v3/examples"


def repair_case() -> RepairCaseV3:
    return decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())


def decision_value() -> dict[str, Any]:
    value = json.loads((FIXTURES / "repair-decision-join.json").read_bytes())
    assert isinstance(value, dict)
    return value


class ScriptedResponseModel:
    def __init__(self, result: object | Exception) -> None:
        self.result = result
        self.calls: list[ChatRequest] = []
        self.closed = False

    async def complete(self, request: ChatRequest) -> object:
        self.calls.append(request)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result

    async def close(self) -> None:
        self.closed = True


def test_settings() -> OllamaSettings:
    return OllamaSettings(
        base_url="https://ollama.example",
        ca_file=None,
        client_cert_file=Path("client.pem"),
        client_key_file=Path("client-key.pem"),
        context_tokens=32768,
        output_tokens=4096,
        reasoning=True,
        timeout_seconds=5,
    )


def chat_response(
    content: object,
    *,
    reasoning: str | None = None,
    done_reason: str | None = None,
    eval_count: int | None = None,
) -> ChatResponse:
    message = Message.model_construct(
        role="assistant",
        content=content,
        thinking=reasoning,
    )
    return ChatResponse(
        message=message,
        done_reason=done_reason,
        eval_count=eval_count,
    )


async def test_decision_model_sends_case_as_messages() -> None:
    chat = ScriptedResponseModel(chat_response(json.dumps(decision_value())))
    case = repair_case()

    result = await OllamaDecisionModel(chat, test_settings()).decide("system instruction", case)

    assert result.root.case_id.root == case.case_id.root
    request = chat.calls[0]
    assert request.model == MODEL_NAME
    system_content = request.messages[0]["content"]
    assert system_content == "system instruction"
    assert request.messages[1] == {"role": "user", "content": project_case(case).case_content}
    assert request.schema == decision_schema()
    assert request.context_tokens == 32768
    assert request.output_tokens == 4096
    assert request.reasoning


async def test_decision_model_closes_client() -> None:
    chat = ScriptedResponseModel(chat_response(json.dumps(decision_value())))
    model = OllamaDecisionModel(chat, test_settings())

    await model.close()

    assert chat.closed


async def test_decision_model_wraps_runnable_failure() -> None:
    chat = ScriptedResponseModel(RuntimeError("transport failed"))

    with pytest.raises(
        DecisionModelError,
        match=r"Ollama request.*RuntimeError: transport failed",
    ):
        await OllamaDecisionModel(chat, test_settings()).decide("system instruction", repair_case())


@pytest.mark.parametrize(
    ("result", "message", "violation_code"),
    [
        (None, "response was not a chat response", None),
        (chat_response([]), "output was not text", None),
        (chat_response("[]"), "output was not an object", ViolationCode.NON_OBJECT_JSON),
        (chat_response("not JSON"), "decoding failed", ViolationCode.INVALID_JSON),
        (chat_response("{}"), "decision contract failed", ViolationCode.MISSING_FIELD),
        (
            chat_response('{"action":"no_repair"}{"action":"no_repair"}'),
            "decoding failed",
            ViolationCode.EXTRA_OUTPUT,
        ),
    ],
)
async def test_decision_model_rejects_invalid_response(
    result: object,
    message: str,
    violation_code: ViolationCode | None,
) -> None:
    chat = ScriptedResponseModel(result)

    with pytest.raises(DecisionModelError, match=message) as raised:
        await OllamaDecisionModel(chat, test_settings()).decide("system instruction", repair_case())

    assert tuple(violation.code for violation in raised.value.violations) == (
        () if violation_code is None else (violation_code,)
    )


async def test_decision_model_adds_correction_to_trusted_instruction() -> None:
    chat = ScriptedResponseModel(chat_response(json.dumps(decision_value())))
    case = repair_case()
    correction = (
        DecisionViolation(
            ViolationCode.UNKNOWN_EVIDENCE,
            ("evidence_refs",),
            rejected_values=("download_01",),
            allowed_values=("evidence_queue_01",),
        ),
    )

    await OllamaDecisionModel(chat, test_settings()).decide(
        "system instruction",
        case,
        correction,
    )

    content = chat.calls[0].messages[0]["content"]
    assert content.endswith(format_correction(project_case(case).project_correction(correction)))


async def test_decision_model_traces_raw_parse_failure(tmp_path: Path) -> None:
    path = tmp_path / "trace.jsonl"
    case = repair_case()
    raw = chat_response(
        '{"action":',
        reasoning="I should join the ordered parts.",
        done_reason="length",
        eval_count=4096,
    )
    chat = ScriptedResponseModel(raw)

    with (
        JsonlTraceWriter(path, {case.case_id.root: "clear_ordered_join"}) as trace,
        pytest.raises(DecisionModelError, match="structured decoding failed"),
    ):
        await OllamaDecisionModel(chat, test_settings(), trace).decide("system instruction", case)

    value = json.loads(path.read_text())
    assert value["case_name"] == "clear_ordered_join"
    assert value["attempt"] == 1
    assert value["case_id"] == case.case_id.root
    assert value["raw_output"] == '{"action":'
    assert value["reasoning"] == "I should join the ordered parts."
    assert value["response_metadata"] == {
        "done_reason": "length",
        "eval_count": 4096,
    }
    assert value["error"].startswith("structured decoding failed: JSONDecodeError:")
    assert path.stat().st_mode & 0o777 == 0o600


def test_trace_writer_numbers_attempts(tmp_path: Path) -> None:
    path = tmp_path / "trace.jsonl"
    trace = ModelTrace(
        case_id="sha256:" + "a" * 64,
        raw_output=None,
        reasoning=None,
        response_metadata={},
        error="request failed",
    )

    with JsonlTraceWriter(path, {}) as writer:
        writer.record(trace)
        writer.record(trace)

    values = [json.loads(line) for line in path.read_text().splitlines()]
    assert [value["attempt"] for value in values] == [1, 2]


class RecordingOllamaServer(ThreadingHTTPServer):
    request_values: Queue[dict[str, Any]]
    response_value: dict[str, Any]


class OllamaHandler(BaseHTTPRequestHandler):
    server: RecordingOllamaServer

    def do_POST(self) -> None:
        size = int(self.headers["Content-Length"])
        request_value = json.loads(self.rfile.read(size))
        assert isinstance(request_value, dict)
        peer_certificate = self.connection.getpeercert()
        request_value["test_peer_certificate"] = peer_certificate
        request_value["test_authorization"] = self.headers.get("Authorization")
        self.server.request_values.put(request_value)

        response = {
            "model": MODEL_NAME,
            "created_at": "2026-09-07T00:00:00Z",
            "message": {
                "role": "assistant",
                "content": json.dumps(self.server.response_value),
            },
            "done": True,
            "done_reason": "stop",
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
def ollama_tls_server(
    tmp_path: Path,
    *,
    require_client_certificate: bool = True,
) -> Iterator[tuple[str, Path, Path, Path, Queue]]:
    ca = trustme.CA()
    server_identity = ca.issue_cert("localhost")
    client_identity = ca.issue_cert("media-repair-planner")

    ca_file = tmp_path / "ca.pem"
    client_cert_file = tmp_path / "client.pem"
    client_key_file = tmp_path / "client-key.pem"
    ca.cert_pem.write_to_path(ca_file)
    client_identity.cert_chain_pems[0].write_to_path(client_cert_file)
    client_identity.private_key_pem.write_to_path(client_key_file)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_identity.configure_cert(context)
    if require_client_certificate:
        ca.configure_trust(context)
        context.verify_mode = ssl.CERT_REQUIRED

    requests: Queue[dict[str, Any]] = Queue()
    server = RecordingOllamaServer(("localhost", 0), OllamaHandler)
    server.request_values = requests
    server.response_value = decision_value()
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        del host
        yield f"https://localhost:{port}", ca_file, client_cert_file, client_key_file, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


async def test_real_client_uses_mtls_and_native_schema(tmp_path: Path) -> None:
    case = repair_case()
    with ollama_tls_server(tmp_path) as (
        base_url,
        ca_file,
        client_cert_file,
        client_key_file,
        requests,
    ):
        settings = OllamaSettings(
            base_url=base_url,
            ca_file=ca_file,
            client_cert_file=client_cert_file,
            client_key_file=client_key_file,
            context_tokens=32768,
            output_tokens=4096,
            reasoning=True,
            timeout_seconds=5,
        )

        model = OllamaDecisionModel.from_settings(settings)
        try:
            result = await model.decide("system instruction", case)
        finally:
            await model.close()

    assert result.root.case_id.root == case.case_id.root
    request = requests.get_nowait()
    assert request["model"] == MODEL_NAME
    assert request["stream"] is False
    assert request["think"] is True
    assert request["format"] == decision_schema()
    assert request["options"] == {
        "num_ctx": 32768,
        "num_predict": 4096,
        "temperature": 0.0,
    }
    assert request["messages"] == [
        {
            "role": "system",
            "content": "system instruction",
        },
        {"role": "user", "content": project_case(case).case_content},
    ]
    assert request["test_peer_certificate"]
    assert request["test_authorization"] is None


async def test_real_client_uses_bearer_token_without_client_certificate(tmp_path: Path) -> None:
    case = repair_case()
    api_key_file = tmp_path / "api-key"
    api_key_file.write_text("cloud-secret\n", encoding="utf-8")
    with ollama_tls_server(tmp_path, require_client_certificate=False) as (
        base_url,
        ca_file,
        _client_cert_file,
        _client_key_file,
        requests,
    ):
        settings = OllamaSettings(
            base_url=base_url,
            ca_file=ca_file,
            client_cert_file=None,
            client_key_file=None,
            api_key_file=api_key_file,
            context_tokens=32768,
            output_tokens=4096,
            reasoning=False,
            timeout_seconds=5,
        )

        model = OllamaDecisionModel.from_settings(settings)
        try:
            result = await model.decide("system instruction", case)
        finally:
            await model.close()

    assert result.root.case_id.root == case.case_id.root
    request = requests.get_nowait()
    assert request["test_authorization"] == "Bearer cloud-secret"
    assert not request["test_peer_certificate"]


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"base_url": "http://frame:11434"}, "HTTPS"),
        ({"base_url": "https://user:secret@frame"}, "credentials"),
        ({"context_tokens": 0}, "context token"),
        ({"output_tokens": 0}, "output token"),
        ({"output_tokens": 32769}, "output token"),
        ({"timeout_seconds": float("inf")}, "timeout"),
        ({"model": ""}, "model name"),
        ({"model": " granite4:32b-a9b-h"}, "model name"),
        ({"client_key_file": None}, "configured together"),
        ({"client_cert_file": None}, "configured together"),
        ({"api_key_file": Path("api-key")}, "exclusive"),
        (
            {"client_cert_file": None, "client_key_file": None},
            "authentication must be configured",
        ),
    ],
)
def test_settings_reject_unsafe_values(changes: dict[str, object], message: str) -> None:
    values: dict[str, object] = {
        "base_url": "https://frame:11434",
        "ca_file": Path("ca.pem"),
        "client_cert_file": Path("client.pem"),
        "client_key_file": Path("client-key.pem"),
        "context_tokens": 32768,
        "output_tokens": 4096,
        "reasoning": True,
        "timeout_seconds": 5,
    }
    values.update(changes)

    with pytest.raises(OllamaConfigurationError, match=message):
        OllamaSettings(**values)


def test_model_rejects_unreadable_tls_credentials(tmp_path: Path) -> None:
    settings = OllamaSettings(
        base_url="https://frame:11434",
        ca_file=tmp_path / "missing-ca.pem",
        client_cert_file=tmp_path / "missing-client.pem",
        client_key_file=tmp_path / "missing-key.pem",
        context_tokens=32768,
        output_tokens=4096,
        reasoning=False,
        timeout_seconds=5,
    )

    with pytest.raises(OllamaConfigurationError, match="TLS credentials"):
        OllamaDecisionModel.from_settings(settings)


@pytest.mark.parametrize("value", ["", " secret", "secret ", "secret\nsecond"])
def test_model_rejects_invalid_api_key(tmp_path: Path, value: str) -> None:
    api_key_file = tmp_path / "api-key"
    api_key_file.write_text(value, encoding="utf-8")
    settings = OllamaSettings(
        base_url="https://ollama.com",
        ca_file=None,
        client_cert_file=None,
        client_key_file=None,
        api_key_file=api_key_file,
        context_tokens=32768,
        output_tokens=4096,
        reasoning=False,
        timeout_seconds=5,
    )

    with pytest.raises(OllamaConfigurationError, match="API key must be non-empty and trimmed"):
        OllamaDecisionModel.from_settings(settings)


def test_model_rejects_unreadable_api_key(tmp_path: Path) -> None:
    settings = OllamaSettings(
        base_url="https://ollama.com",
        ca_file=None,
        client_cert_file=None,
        client_key_file=None,
        api_key_file=tmp_path / "missing-api-key",
        context_tokens=32768,
        output_tokens=4096,
        reasoning=False,
        timeout_seconds=5,
    )

    with pytest.raises(OllamaConfigurationError, match="failed to load Ollama API key"):
        OllamaDecisionModel.from_settings(settings)
