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
from langchain_core.language_models import LanguageModelInput
from langchain_core.messages import BaseMessage
from langchain_core.runnables import RunnableConfig
from radarr_repair_planner.case_models import RepairCaseV1
from radarr_repair_planner.contracts import (
    decision_schema,
    decode_case,
    encode_case,
)
from radarr_repair_planner.ollama_model import (
    MODEL_NAME,
    OllamaConfigurationError,
    OllamaDecisionModel,
    OllamaSettings,
)
from radarr_repair_planner.planning import DecisionModelError

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v1/examples"


def repair_case() -> RepairCaseV1:
    return decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())


def decision_value() -> dict[str, Any]:
    value = json.loads((FIXTURES / "repair-decision-join.json").read_bytes())
    assert isinstance(value, dict)
    return value


class ScriptedStructuredModel:
    def __init__(self, result: object | Exception) -> None:
        self.result = result
        self.calls: list[tuple[LanguageModelInput, dict[str, Any]]] = []

    async def ainvoke(
        self,
        input: LanguageModelInput,
        config: RunnableConfig | None = None,
        **kwargs: Any,
    ) -> object:
        del config
        self.calls.append((input, kwargs))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


async def test_decision_model_sends_case_as_messages() -> None:
    chat = ScriptedStructuredModel(decision_value())
    case = repair_case()

    result = await OllamaDecisionModel(chat).decide("system instruction", case)

    assert result.root.case_id.root == case.case_id.root
    messages, kwargs = chat.calls[0]
    assert isinstance(messages, list)
    assert all(isinstance(message, BaseMessage) for message in messages)
    assert [(message.type, message.content) for message in messages] == [
        ("system", "system instruction"),
        ("human", encode_case(case).decode()),
    ]
    assert kwargs == {"stream": False}


async def test_decision_model_wraps_runnable_failure() -> None:
    chat = ScriptedStructuredModel(RuntimeError("transport failed"))

    with pytest.raises(DecisionModelError, match="Ollama request"):
        await OllamaDecisionModel(chat).decide("system instruction", repair_case())


@pytest.mark.parametrize("result", [None, [], {"action": object()}])
async def test_decision_model_rejects_non_json_object(result: object) -> None:
    chat = ScriptedStructuredModel(result)

    with pytest.raises(DecisionModelError, match="structured output"):
        await OllamaDecisionModel(chat).decide("system instruction", repair_case())


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
def ollama_tls_server(tmp_path: Path) -> Iterator[tuple[str, Path, Path, Path, Queue]]:
    ca = trustme.CA()
    server_identity = ca.issue_cert("localhost")
    client_identity = ca.issue_cert("radarr-repair-planner")

    ca_file = tmp_path / "ca.pem"
    client_cert_file = tmp_path / "client.pem"
    client_key_file = tmp_path / "client-key.pem"
    ca.cert_pem.write_to_path(ca_file)
    client_identity.cert_chain_pems[0].write_to_path(client_cert_file)
    client_identity.private_key_pem.write_to_path(client_key_file)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_identity.configure_cert(context)
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

        result = await OllamaDecisionModel.from_settings(settings).decide(
            "system instruction",
            case,
        )

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
        {"role": "system", "content": "system instruction"},
        {"role": "user", "content": encode_case(case).decode()},
    ]
    assert request["test_peer_certificate"]


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"base_url": "http://frame:11434"}, "HTTPS"),
        ({"base_url": "https://user:secret@frame"}, "credentials"),
        ({"context_tokens": 0}, "context token"),
        ({"output_tokens": 0}, "output token"),
        ({"output_tokens": 32769}, "output token"),
        ({"timeout_seconds": float("inf")}, "timeout"),
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
