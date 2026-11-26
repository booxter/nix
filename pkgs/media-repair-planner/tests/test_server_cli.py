from __future__ import annotations

import socket
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI
from media_repair_planner.decision_validation_core import DecisionViolation
from media_repair_planner.openrouter_model import OpenRouterSettings
from media_repair_planner.server_cli import main, validate_socket
from media_repair_planner.structured_model import StructuredModelResponse
from media_repair_planner.usage import UsageSink
from pydantic import BaseModel


class CloseableModel:
    def __init__(self) -> None:
        self.closed = False

    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> StructuredModelResponse:
        del system_instruction, case_content, decision_model, case_id, correction
        raise AssertionError("readiness must not invoke the model")

    async def close(self) -> None:
        self.closed = True


class RecordingServer:
    def __init__(self, failure: Exception | None = None) -> None:
        self.failure = failure
        self.socket_fds: list[int] = []
        self.readiness: list[dict[str, str]] = []

    async def serve(self, app: FastAPI, socket_fd: int) -> None:
        self.socket_fds.append(socket_fd)
        if self.failure is not None:
            raise self.failure
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://planner") as client:
            response = await client.get("/ready")
        self.readiness.append(response.json())


def server_arguments(api_key_file: Path) -> list[str]:
    return [
        "--model",
        "openai/gpt-5.6-sol",
        "--openrouter-provider",
        "OpenAI",
        "--openrouter-api-key-file",
        str(api_key_file),
        "--output-tokens",
        "4096",
        "--reasoning",
        "high",
        "--timeout-seconds",
        "120",
        "--socket-fd",
        "3",
        "--planning-timeout-seconds",
        "300",
    ]


def test_server_builds_app_from_typed_settings_and_closes_model(tmp_path: Path) -> None:
    api_key_file = tmp_path / "openrouter-api-key"
    model = CloseableModel()
    settings_seen: list[OpenRouterSettings] = []
    runner = RecordingServer()

    def model_factory(
        settings: OpenRouterSettings,
        usage_sink: UsageSink | None,
    ) -> CloseableModel:
        del usage_sink
        settings_seen.append(settings)
        return model

    result = main(
        server_arguments(api_key_file),
        model_factory=model_factory,
        server_runner=runner,
    )

    assert result == 0
    assert settings_seen == [
        OpenRouterSettings(
            api_key_file=api_key_file,
            model="openai/gpt-5.6-sol",
            provider="OpenAI",
            output_tokens=4096,
            reasoning_effort="high",
            timeout_seconds=120,
        )
    ]
    assert runner.socket_fds == [3]
    assert runner.readiness == [{"status": "ready"}]
    assert model.closed


def test_server_closes_model_after_runner_failure(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    model = CloseableModel()

    def model_factory(
        settings: OpenRouterSettings,
        usage_sink: UsageSink | None,
    ) -> CloseableModel:
        del settings, usage_sink
        return model

    result = main(
        server_arguments(tmp_path / "openrouter-api-key"),
        model_factory=model_factory,
        server_runner=RecordingServer(ValueError("server failed")),
    )

    assert result == 2
    assert model.closed
    assert capsys.readouterr().err == "error: server failed\n"


def test_server_rejects_invalid_planning_timeout(tmp_path: Path) -> None:
    arguments = server_arguments(tmp_path / "openrouter-api-key")
    arguments[arguments.index("--planning-timeout-seconds") + 1] = "0"

    result = main(arguments, server_runner=RecordingServer())

    assert result == 2


def test_accepts_named_unix_listener(tmp_path: Path) -> None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(tmp_path / "planner.sock"))
        listener.listen()

        validate_socket(listener.fileno())


def test_rejects_tcp_listener() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()

        with pytest.raises(ValueError, match="inherited socket"):
            validate_socket(listener.fileno())


def test_rejects_non_listening_unix_socket() -> None:
    first, second = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    with first, second, pytest.raises(ValueError, match="listening stream socket"):
        validate_socket(first.fileno())
