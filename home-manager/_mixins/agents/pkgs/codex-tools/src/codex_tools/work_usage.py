import math
from dataclasses import dataclass
from datetime import datetime, timezone

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient
from codex_tools.json import (
    JsonObject,
    boolean_value,
    number_value,
    object_value,
    string_value,
)
from codex_tools.usage import USAGE_ENDPOINT


def _coerce_number(value: object) -> int | float | None:
    number = number_value(value)
    if number is not None:
        return number
    if not isinstance(value, str):
        return None
    try:
        return float(value) if "." in value else int(value)
    except ValueError:
        return None


@dataclass(frozen=True)
class WorkCredits:
    has_credits: bool
    unlimited: bool
    overage_limit_reached: bool
    balance: int | float | None

    def to_json(self) -> JsonObject:
        return {
            "has_credits": self.has_credits,
            "unlimited": self.unlimited,
            "overage_limit_reached": self.overage_limit_reached,
            "balance": self.balance,
        }


@dataclass(frozen=True)
class WorkUsage:
    account_id: str | None
    email: str | None
    plan_type: str | None
    reached: bool
    source: str | None
    limit: int | float | None
    used: int | float | None
    remaining: int | float | None
    used_percent: int | float | None
    remaining_percent: int | float | None
    reset_after_seconds: int | float | None
    reset_at: int | float | None
    window_start_at: int
    window_seconds: int | None
    elapsed_seconds: int
    credits: WorkCredits

    def to_json(self) -> JsonObject:
        return {
            "account_id": self.account_id,
            "email": self.email,
            "plan_type": self.plan_type,
            "reached": self.reached,
            "source": self.source,
            "limit": self.limit,
            "used": self.used,
            "remaining": self.remaining,
            "used_percent": self.used_percent,
            "remaining_percent": self.remaining_percent,
            "reset_after_seconds": self.reset_after_seconds,
            "reset_at": self.reset_at,
            "window_start_at": self.window_start_at,
            "window_seconds": self.window_seconds,
            "elapsed_seconds": self.elapsed_seconds,
            "credits": self.credits.to_json(),
        }


def normalize_work_usage(response: JsonObject, *, now: float) -> WorkUsage:
    spend_control = object_value(response, "spend_control") or {}
    individual_limit = object_value(spend_control, "individual_limit")
    if individual_limit is None:
        raise CodexToolsError("Missing spend_control.individual_limit in usage response")

    current = datetime.fromtimestamp(now, timezone.utc)
    window_start = datetime(current.year, current.month, 1, tzinfo=timezone.utc).timestamp()
    reset_at = _coerce_number(individual_limit.get("reset_at"))
    credits = object_value(response, "credits") or {}
    return WorkUsage(
        account_id=string_value(response.get("account_id")),
        email=string_value(response.get("email")),
        plan_type=string_value(response.get("plan_type")),
        reached=boolean_value(spend_control.get("reached")) or False,
        source=string_value(individual_limit.get("source")),
        limit=_coerce_number(individual_limit.get("limit")),
        used=_coerce_number(individual_limit.get("used")),
        remaining=_coerce_number(individual_limit.get("remaining")),
        used_percent=_coerce_number(individual_limit.get("used_percent")),
        remaining_percent=_coerce_number(individual_limit.get("remaining_percent")),
        reset_after_seconds=_coerce_number(individual_limit.get("reset_after_seconds")),
        reset_at=reset_at,
        window_start_at=math.floor(window_start),
        window_seconds=(math.floor(reset_at - window_start) if reset_at is not None else None),
        elapsed_seconds=math.floor(now - window_start),
        credits=WorkCredits(
            has_credits=boolean_value(credits.get("has_credits")) or False,
            unlimited=boolean_value(credits.get("unlimited")) or False,
            overage_limit_reached=(boolean_value(credits.get("overage_limit_reached")) or False),
            balance=_coerce_number(credits.get("balance")),
        ),
    )


@dataclass(frozen=True)
class WorkUsageService:
    client: JsonHttpClient
    usage_endpoint: str = USAGE_ENDPOINT

    def fetch(self, auth: CodexAuth, *, now: float) -> WorkUsage:
        if not auth.account_id:
            raise CodexToolsError("Codex account ID is required for work usage")
        response = self.client.get_json(
            self.usage_endpoint,
            headers={
                "Authorization": f"Bearer {auth.access_token}",
                "ChatGPT-Account-Id": auth.account_id,
                "OAI-Language": "en-US",
                "originator": "codex_desktop",
            },
        )
        return normalize_work_usage(response, now=now)


def format_work_usage(usage: WorkUsage) -> str:
    def display(value: object) -> object:
        return "?" if value is None else value

    return "\n".join(
        (
            f"remaining: {display(usage.remaining_percent)}%",
            f"used: {display(usage.used_percent)}%",
            f"credits: {display(usage.remaining)} / {display(usage.limit)}",
            f"reset_after_seconds: {display(usage.reset_after_seconds)}",
            f"reset_at: {display(usage.reset_at)}",
        )
    )
