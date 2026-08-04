import io
import json
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from codex_tools.auth import CodexAuth
from codex_tools.cli import warmer_main
from codex_tools.errors import CodexToolsError
from codex_tools.usage import RESET_CREDITS_ENDPOINT, USAGE_ENDPOINT, PersonalUsageService
from codex_tools.warmer import (
    RESPONSES_ENDPOINT,
    OpenAIResponsesClient,
    WarmerService,
    WarmupRequest,
)
from fakes import FakeJsonHttpClient


@dataclass(frozen=True)
class ResponsesRequest:
    auth: CodexAuth
    endpoint: str
    request: WarmupRequest


@dataclass
class FakeResponsesClient:
    event_types: tuple[str, ...]
    requests: list[ResponsesRequest] = field(default_factory=list)

    def stream_event_types(
        self,
        auth: CodexAuth,
        *,
        endpoint: str,
        request: WarmupRequest,
    ) -> tuple[str, ...]:
        self.requests.append(ResponsesRequest(auth, endpoint, request))
        return self.event_types


def usage_response(
    five_hour_reset_after_seconds: int | None,
    weekly_reset_after_seconds: int | None = None,
) -> dict[str, object]:
    windows = [
        {
            "limit_window_seconds": limit_window_seconds,
            "reset_after_seconds": reset_after_seconds,
        }
        for limit_window_seconds, reset_after_seconds in (
            (18_000, five_hour_reset_after_seconds),
            (604_800, weekly_reset_after_seconds),
        )
        if reset_after_seconds is not None
    ]
    return {
        "rate_limit": {
            "primary_window": windows[0] if windows else None,
            "secondary_window": windows[1] if len(windows) > 1 else None,
        }
    }


def fake_client(
    five_hour_reset_after_seconds: int | None,
    weekly_reset_after_seconds: int | None = None,
) -> FakeJsonHttpClient:
    return FakeJsonHttpClient(
        responses={
            USAGE_ENDPOINT: usage_response(
                five_hour_reset_after_seconds,
                weekly_reset_after_seconds,
            ),
            RESET_CREDITS_ENDPOINT: {"available_count": 0, "credits": []},
        }
    )


def test_does_nothing_while_five_hour_window_is_ticking() -> None:
    client = fake_client(17_999)
    responses = FakeResponsesClient(("response.completed",))

    assert not WarmerService(PersonalUsageService(client), responses).warm_if_needed(
        CodexAuth("test-token", "test-account"),
        now=0,
    )
    assert responses.requests == []


def test_does_nothing_without_rate_limit_windows() -> None:
    client = fake_client(None, None)
    responses = FakeResponsesClient(("response.completed",))

    assert not WarmerService(PersonalUsageService(client), responses).warm_if_needed(
        CodexAuth("test-token", "test-account"),
        now=0,
    )
    assert responses.requests == []


def test_does_nothing_while_only_weekly_window_is_ticking() -> None:
    client = fake_client(None, 604_799)
    responses = FakeResponsesClient(("response.completed",))

    assert not WarmerService(PersonalUsageService(client), responses).warm_if_needed(
        CodexAuth("test-token", "test-account"),
        now=0,
    )
    assert responses.requests == []


def test_starts_inactive_weekly_window_without_five_hour_window() -> None:
    client = fake_client(None, 0)
    responses = FakeResponsesClient(("response.completed",))

    assert WarmerService(PersonalUsageService(client), responses).warm_if_needed(
        CodexAuth("test-token", "test-account"),
        now=0,
    )
    assert len(responses.requests) == 1


def test_starts_when_either_window_is_inactive() -> None:
    client = fake_client(17_999, 0)
    responses = FakeResponsesClient(("response.completed",))

    assert WarmerService(PersonalUsageService(client), responses).warm_if_needed(
        CodexAuth("test-token", "test-account"),
        now=0,
    )
    assert len(responses.requests) == 1


def test_starts_inactive_window_with_minimal_request() -> None:
    client = fake_client(0)
    responses = FakeResponsesClient(("response.completed",))

    assert WarmerService(PersonalUsageService(client), responses).warm_if_needed(
        CodexAuth("test-token", "test-account"),
        now=0,
    )

    call = responses.requests[0]
    assert call.auth == CodexAuth("test-token", "test-account")
    assert call.endpoint == RESPONSES_ENDPOINT
    assert call.request == WarmupRequest(
        model="gpt-5.4-mini",
        instructions="Reply with exactly OK.",
        prompt="OK",
        reasoning_effort="low",
        verbosity="low",
    )


def test_requires_account_id_to_start_window() -> None:
    responses = FakeResponsesClient(("response.completed",))

    with pytest.raises(CodexToolsError, match="account ID is required"):
        WarmerService(PersonalUsageService(fake_client(0)), responses).warm_if_needed(
            CodexAuth("test-token", None),
            now=0,
        )

    assert responses.requests == []


def test_openai_client_rejects_invalid_endpoint() -> None:
    with pytest.raises(CodexToolsError, match="must end with /responses"):
        OpenAIResponsesClient().stream_event_types(
            CodexAuth("test-token", "test-account"),
            endpoint="https://example.invalid/not-responses",
            request=WarmupRequest(),
        )


def test_warmer_main_fails_when_response_does_not_complete(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    auth_path.write_text(
        json.dumps({"tokens": {"access_token": "token", "account_id": "account"}}),
        encoding="utf-8",
    )
    client = fake_client(0)
    responses = FakeResponsesClient(("response.failed",))
    stderr = io.StringIO()

    status = warmer_main(
        ["--auth-file", str(auth_path)],
        client=client,
        responses_client=responses,
        now=0,
        environ={"CODEX_WARMER_RESPONSES_ENDPOINT": "https://example.invalid/responses"},
        stderr=stderr,
    )

    assert status == 1
    assert "Codex warm-up request did not complete" in stderr.getvalue()
    assert responses.requests[0].endpoint == "https://example.invalid/responses"


def test_warmer_main_reports_warmup_request(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    auth_path.write_text(
        json.dumps({"tokens": {"access_token": "token", "account_id": "account"}}),
        encoding="utf-8",
    )
    stdout = io.StringIO()

    status = warmer_main(
        ["--auth-file", str(auth_path)],
        client=fake_client(0),
        responses_client=FakeResponsesClient(("response.completed",)),
        now=0,
        environ={},
        stdout=stdout,
    )

    assert status == 0
    assert stdout.getvalue() == "Sent a Codex usage warm-up request.\n"
