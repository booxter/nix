import math
from dataclasses import dataclass
from datetime import datetime
from typing import Final

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient
from codex_tools.json import (
    JsonObject,
    boolean_value,
    integer_value,
    number_value,
    object_list,
    object_value,
    string_value,
)

USAGE_ENDPOINT: Final = "https://chatgpt.com/backend-api/wham/usage"
RESET_CREDITS_ENDPOINT: Final = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
FIVE_HOURS: Final = 18_000
ONE_WEEK: Final = 604_800


@dataclass(frozen=True)
class UsageWindow:
    used_percent: int | float | None
    remaining_percent: int | None
    limit_window_seconds: int | None
    reset_after_seconds: int | None
    reset_at: int | float | None

    @classmethod
    def from_json(cls, source: JsonObject) -> "UsageWindow":
        used_percent = number_value(source.get("used_percent"))
        return cls(
            used_percent=used_percent,
            remaining_percent=(
                math.floor(100 - used_percent) if used_percent is not None else None
            ),
            limit_window_seconds=integer_value(source.get("limit_window_seconds")),
            reset_after_seconds=integer_value(source.get("reset_after_seconds")),
            reset_at=number_value(source.get("reset_at")),
        )

    def to_json(self) -> JsonObject:
        return {
            "used_percent": self.used_percent,
            "remaining_percent": self.remaining_percent,
            "limit_window_seconds": self.limit_window_seconds,
            "reset_after_seconds": self.reset_after_seconds,
            "reset_at": self.reset_at,
        }


@dataclass(frozen=True)
class ResetCredit:
    expires_at: str | None
    expires_at_unix: int | None
    expires_after_seconds: int | None

    def to_json(self) -> JsonObject:
        return {
            "expires_at": self.expires_at,
            "expires_at_unix": self.expires_at_unix,
            "expires_after_seconds": self.expires_after_seconds,
        }


@dataclass(frozen=True)
class ResetCredits:
    available_count: int
    credits: tuple[ResetCredit, ...]
    next_credit: ResetCredit | None

    def to_json(self) -> JsonObject:
        return {
            "available_count": self.available_count,
            "credits": [credit.to_json() for credit in self.credits],
            "next_expires_at": self.next_credit.expires_at if self.next_credit else None,
            "next_expires_at_unix": (
                self.next_credit.expires_at_unix if self.next_credit else None
            ),
            "next_expires_after_seconds": (
                self.next_credit.expires_after_seconds if self.next_credit else None
            ),
        }


@dataclass(frozen=True)
class PersonalUsage:
    allowed: bool | None
    limit_reached: bool | None
    limit_reached_type: str | None
    five_hour: UsageWindow | None
    weekly: UsageWindow | None
    reset_credits: ResetCredits

    def to_json(self) -> JsonObject:
        return {
            "allowed": self.allowed,
            "limit_reached": self.limit_reached,
            "limit_reached_type": self.limit_reached_type,
            "windows": {
                "five_hour": self.five_hour.to_json() if self.five_hour else None,
                "weekly": self.weekly.to_json() if self.weekly else None,
            },
            "rate_limit_reset_credits": self.reset_credits.to_json(),
        }


def _window_kind(source: JsonObject | None) -> str | None:
    if source is None:
        return None
    duration = integer_value(source.get("limit_window_seconds"))
    if duration == FIVE_HOURS:
        return "five_hour"
    if duration == ONE_WEEK:
        return "weekly"
    return None


def _parse_expiry(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError):
        return None
    return math.floor(timestamp)


def _reset_credits(
    source: JsonObject,
    fallback: JsonObject | None,
    *,
    now: float,
) -> ResetCredits:
    credits: list[ResetCredit] = []
    for item in object_list(source, "credits"):
        expires_at = string_value(item.get("expires_at"))
        expires_at_unix = _parse_expiry(expires_at)
        credits.append(
            ResetCredit(
                expires_at=expires_at,
                expires_at_unix=expires_at_unix,
                expires_after_seconds=(
                    math.floor(expires_at_unix - now) if expires_at_unix is not None else None
                ),
            )
        )
    future = [
        credit
        for credit in credits
        if credit.expires_after_seconds is not None and credit.expires_after_seconds >= 0
    ]
    next_credit = min(future, key=lambda credit: credit.expires_after_seconds or 0, default=None)
    available_count = integer_value(source.get("available_count"))
    if available_count is None and fallback is not None:
        available_count = integer_value(fallback.get("available_count"))
    return ResetCredits(
        available_count=available_count or 0,
        credits=tuple(credits),
        next_credit=next_credit,
    )


def normalize_personal_usage(
    response: JsonObject,
    reset_details: JsonObject | None,
    *,
    now: float,
) -> PersonalUsage:
    rate_limit = object_value(response, "rate_limit") or {}
    primary = object_value(rate_limit, "primary_window")
    secondary = object_value(rate_limit, "secondary_window")
    by_kind = {_window_kind(window): window for window in (primary, secondary)}
    fallback_credits = object_value(response, "rate_limit_reset_credits")
    reset_source = reset_details or fallback_credits or {}

    reached_type = string_value(response.get("rate_limit_reached_type"))
    if reached_type in {"primary", "primary_window"}:
        reached_type = _window_kind(primary) or reached_type
    elif reached_type in {"secondary", "secondary_window"}:
        reached_type = _window_kind(secondary) or reached_type

    five_hour = by_kind.get("five_hour")
    weekly = by_kind.get("weekly")
    return PersonalUsage(
        allowed=boolean_value(rate_limit.get("allowed")),
        limit_reached=boolean_value(rate_limit.get("limit_reached")),
        limit_reached_type=reached_type,
        five_hour=UsageWindow.from_json(five_hour) if five_hour else None,
        weekly=UsageWindow.from_json(weekly) if weekly else None,
        reset_credits=_reset_credits(reset_source, fallback_credits, now=now),
    )


@dataclass(frozen=True)
class PersonalUsageService:
    client: JsonHttpClient
    usage_endpoint: str = USAGE_ENDPOINT
    reset_credits_endpoint: str = RESET_CREDITS_ENDPOINT

    def fetch(self, auth: CodexAuth, *, now: float) -> PersonalUsage:
        headers = {"Authorization": f"Bearer {auth.access_token}"}
        response = self.client.get_json(self.usage_endpoint, headers=headers)
        try:
            reset_details = self.client.get_json(self.reset_credits_endpoint, headers=headers)
        except CodexToolsError:
            reset_details = None
        return normalize_personal_usage(response, reset_details, now=now)


def format_personal_usage(usage: PersonalUsage) -> str:
    def format_bool(value: bool | None) -> str:
        if value is None:
            return "?"
        return "true" if value else "false"

    def format_window(label: str, window: UsageWindow | None) -> str:
        if window is None:
            return f"{label}: unavailable"
        remaining = window.remaining_percent if window.remaining_percent is not None else "?"
        reset_after = window.reset_after_seconds if window.reset_after_seconds is not None else "?"
        reset_at = window.reset_at if window.reset_at is not None else "?"
        return (
            f"{label}: {remaining}% remaining, "
            f"reset_after_seconds={reset_after}, reset_at={reset_at}"
        )

    reset = usage.reset_credits
    reset_line = f"rate_limit_reset_credits: {reset.available_count}"
    if reset.next_credit is not None:
        reset_line += (
            f", next_expires_at={reset.next_credit.expires_at}, "
            f"next_expires_after_seconds={reset.next_credit.expires_after_seconds}"
        )
    return "\n".join(
        (
            f"allowed: {format_bool(usage.allowed)}",
            f"limit_reached: {format_bool(usage.limit_reached)}",
            format_window("5h", usage.five_hour),
            format_window("1w", usage.weekly),
            reset_line,
        )
    )
