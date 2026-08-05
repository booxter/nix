from __future__ import annotations

from typing import Annotated, TypeAlias, TypeVar

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, ValidationError

from codex_tools.errors import CodexToolsError


def _numeric_string(value: object) -> object:
    if not isinstance(value, str):
        return value
    try:
        return float(value) if "." in value else int(value)
    except ValueError:
        return value


Numeric: TypeAlias = Annotated[int | float | None, BeforeValidator(_numeric_string)]


class Payload(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True, allow_inf_nan=False)


class AuthTokensPayload(Payload):
    access_token: str | None = None
    account_id: str | None = None


class AuthPayload(Payload):
    tokens: AuthTokensPayload | None = None


class UsageWindowPayload(Payload):
    used_percent: int | float | None = None
    limit_window_seconds: int | None = None
    reset_after_seconds: int | None = None
    reset_at: int | float | None = None


class RateLimitPayload(Payload):
    allowed: bool | None = None
    limit_reached: bool | None = None
    primary_window: UsageWindowPayload | None = None
    secondary_window: UsageWindowPayload | None = None


class ResetCreditPayload(Payload):
    expires_at: str | None = None


class ResetCreditsPayload(Payload):
    available_count: int | None = None
    credits: list[ResetCreditPayload] = Field(default_factory=list)


class RateLimitReachedTypePayload(Payload):
    type: str | None = None
    details: str | None = None


class PersonalUsagePayload(Payload):
    rate_limit: RateLimitPayload = Field(default_factory=RateLimitPayload)
    rate_limit_reached_type: RateLimitReachedTypePayload | None = None
    rate_limit_reset_credits: ResetCreditsPayload | None = None


class WorkIndividualLimitPayload(Payload):
    source: str | None = None
    limit: Numeric = None
    used: Numeric = None
    remaining: Numeric = None
    used_percent: Numeric = None
    remaining_percent: Numeric = None
    reset_after_seconds: Numeric = None
    reset_at: Numeric = None


class SpendControlPayload(Payload):
    reached: bool | None = None
    individual_limit: WorkIndividualLimitPayload | None = None


class WorkCreditsPayload(Payload):
    has_credits: bool | None = None
    unlimited: bool | None = None
    overage_limit_reached: bool | None = None
    balance: Numeric = None


class WorkUsagePayload(Payload):
    account_id: str | None = None
    email: str | None = None
    plan_type: str | None = None
    spend_control: SpendControlPayload = Field(default_factory=SpendControlPayload)
    credits: WorkCreditsPayload = Field(default_factory=WorkCreditsPayload)


PayloadType = TypeVar("PayloadType", bound=Payload)


def validate_payload(
    model: type[PayloadType],
    value: object,
    *,
    source: str,
) -> PayloadType:
    try:
        return model.model_validate(value)
    except ValidationError as error:
        raise CodexToolsError(f"Invalid {source}: {error}") from error
