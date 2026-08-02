from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.usage import (
    RESET_CREDITS_ENDPOINT,
    USAGE_ENDPOINT,
    PersonalUsageService,
    format_personal_usage,
)
from fakes import FakeJsonHttpClient


def test_normalizes_five_hour_and_weekly_windows_by_duration() -> None:
    client = FakeJsonHttpClient(
        {
            USAGE_ENDPOINT: {
                "rate_limit": {
                    "allowed": True,
                    "limit_reached": False,
                    "primary_window": {
                        "used_percent": 4,
                        "limit_window_seconds": 18_000,
                        "reset_after_seconds": 17_000,
                    },
                    "secondary_window": {
                        "used_percent": 27,
                        "limit_window_seconds": 604_800,
                        "reset_after_seconds": 590_000,
                    },
                }
            },
            RESET_CREDITS_ENDPOINT: {"available_count": 0, "credits": []},
        }
    )

    usage = PersonalUsageService(client).fetch(
        CodexAuth("test-token", None),
        now=1_700_000_000,
    )

    assert usage.five_hour is not None
    assert usage.five_hour.remaining_percent == 96
    assert usage.weekly is not None
    assert usage.weekly.remaining_percent == 73
    assert client.requests[0].headers == {"Authorization": "Bearer test-token"}


def test_recognizes_weekly_window_moved_into_primary_slot() -> None:
    client = FakeJsonHttpClient(
        {
            USAGE_ENDPOINT: {
                "rate_limit": {
                    "allowed": True,
                    "limit_reached": True,
                    "primary_window": {
                        "used_percent": 4,
                        "limit_window_seconds": 604_800,
                        "reset_after_seconds": 590_000,
                    },
                    "secondary_window": None,
                },
                "rate_limit_reached_type": "primary",
            },
            RESET_CREDITS_ENDPOINT: {"available_count": 0, "credits": []},
        }
    )

    usage = PersonalUsageService(client).fetch(CodexAuth("test-token", None), now=0)

    assert usage.five_hour is None
    assert usage.weekly is not None
    assert usage.weekly.remaining_percent == 96
    assert usage.limit_reached_type == "weekly"


def test_uses_fallback_reset_credits_when_optional_request_fails() -> None:
    client = FakeJsonHttpClient(
        {
            USAGE_ENDPOINT: {
                "rate_limit": {},
                "rate_limit_reset_credits": {
                    "available_count": 2,
                    "credits": [{"expires_at": "2023-11-14T22:15:00.000Z"}],
                },
            },
            RESET_CREDITS_ENDPOINT: CodexToolsError("unavailable"),
        }
    )

    usage = PersonalUsageService(client).fetch(
        CodexAuth("test-token", None),
        now=1_700_000_000,
    )

    assert usage.reset_credits.available_count == 2
    assert usage.reset_credits.next_credit is not None
    assert usage.reset_credits.next_credit.expires_after_seconds == 100


def test_formats_text_output() -> None:
    client = FakeJsonHttpClient(
        {
            USAGE_ENDPOINT: {"rate_limit": {"allowed": True, "limit_reached": False}},
            RESET_CREDITS_ENDPOINT: {"available_count": 0, "credits": []},
        }
    )
    usage = PersonalUsageService(client).fetch(CodexAuth("token", None), now=0)

    assert format_personal_usage(usage).splitlines() == [
        "allowed: true",
        "limit_reached: false",
        "5h: unavailable",
        "1w: unavailable",
        "rate_limit_reset_credits: 0",
    ]


def test_normalizes_reset_credit_expiry_and_secondary_limit_type() -> None:
    client = FakeJsonHttpClient(
        {
            USAGE_ENDPOINT: {
                "rate_limit": {
                    "primary_window": {"limit_window_seconds": 123},
                    "secondary_window": {
                        "used_percent": "unknown",
                        "limit_window_seconds": 18_000,
                    },
                },
                "rate_limit_reached_type": "secondary_window",
                "rate_limit_reset_credits": {"available_count": 3},
            },
            RESET_CREDITS_ENDPOINT: {
                "credits": [
                    {"expires_at": "invalid"},
                    "not-an-object",
                    {"expires_at": "2023-11-14T22:15:00Z"},
                ]
            },
        }
    )

    usage = PersonalUsageService(client).fetch(
        CodexAuth("test-token", None),
        now=1_700_000_000,
    )

    assert usage.limit_reached_type == "five_hour"
    assert usage.five_hour is not None
    assert usage.five_hour.remaining_percent is None
    assert usage.reset_credits.available_count == 3
    assert usage.reset_credits.next_credit is not None
    assert usage.reset_credits.next_credit.expires_after_seconds == 100
    assert usage.to_json()["rate_limit_reset_credits"] == {
        "available_count": 3,
        "credits": [
            {
                "expires_at": "invalid",
                "expires_at_unix": None,
                "expires_after_seconds": None,
            },
            {
                "expires_at": "2023-11-14T22:15:00Z",
                "expires_at_unix": 1_700_000_100,
                "expires_after_seconds": 100,
            },
        ],
        "next_expires_at": "2023-11-14T22:15:00Z",
        "next_expires_at_unix": 1_700_000_100,
        "next_expires_after_seconds": 100,
    }
    assert "next_expires_after_seconds=100" in format_personal_usage(usage)
