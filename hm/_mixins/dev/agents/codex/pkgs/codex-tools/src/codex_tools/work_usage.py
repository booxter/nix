import math
from dataclasses import dataclass
from datetime import datetime, timezone

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient
from codex_tools.json import JsonObject
from codex_tools.payloads import WorkUsagePayload, validate_payload
from codex_tools.usage import USAGE_ENDPOINT


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
    payload = validate_payload(WorkUsagePayload, response, source="work usage response")
    spend_control = payload.spend_control
    individual_limit = spend_control.individual_limit
    if individual_limit is None:
        raise CodexToolsError("Missing spend_control.individual_limit in usage response")

    current = datetime.fromtimestamp(now, timezone.utc)
    window_start = datetime(current.year, current.month, 1, tzinfo=timezone.utc).timestamp()
    reset_at = individual_limit.reset_at
    credits = payload.credits
    return WorkUsage(
        account_id=payload.account_id,
        email=payload.email,
        plan_type=payload.plan_type,
        reached=spend_control.reached or False,
        source=individual_limit.source,
        limit=individual_limit.limit,
        used=individual_limit.used,
        remaining=individual_limit.remaining,
        used_percent=individual_limit.used_percent,
        remaining_percent=individual_limit.remaining_percent,
        reset_after_seconds=individual_limit.reset_after_seconds,
        reset_at=reset_at,
        window_start_at=math.floor(window_start),
        window_seconds=(math.floor(reset_at - window_start) if reset_at is not None else None),
        elapsed_seconds=math.floor(now - window_start),
        credits=WorkCredits(
            has_credits=credits.has_credits or False,
            unlimited=credits.unlimited or False,
            overage_limit_reached=credits.overage_limit_reached or False,
            balance=credits.balance,
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
