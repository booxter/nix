"""Read the monthly spend of a Claude Enterprise seat billed by usage.

Such seats have no 5-hour or 7-day windows, so the status line never receives
rate limits. Instead, the applet asks Claude's usage API with the OAuth token
Claude Code keeps in the Keychain. It never refreshes that token: refreshing
rotates the token Claude Code holds and could sign it out.

When the token has expired or the API fails, the applet falls back to the last
usage response Claude Code saved in ~/.claude.json. Claude Code refreshes that
copy only now and then (for example, when /usage runs), so the applet shows
its age.
"""

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pydantic import (
    BaseModel,
    Field,
    NonNegativeFloat,
    NonNegativeInt,
    PositiveFloat,
    ValidationError,
)


class Spend(BaseModel):
    """Spend in minor currency units, for example cents for USD.

    The API sends amounts as JSON numbers that may carry fractions of a cent.
    """

    used: NonNegativeFloat = Field(validation_alias="used_credits")
    limit: PositiveFloat = Field(validation_alias="monthly_limit")
    currency: str
    decimal_places: NonNegativeInt

    def format(self, amount: float) -> str:
        value = amount / 10**self.decimal_places
        return f"{value:,.{self.decimal_places}f} {self.currency}"


class Usage(BaseModel):
    """The part of a usage API response the applet shows."""

    spend: Spend = Field(validation_alias="extra_usage")


class SavedUsage(BaseModel):
    fetched_at_ms: NonNegativeInt = Field(validation_alias="fetchedAtMs")
    usage: Usage = Field(validation_alias="utilization")


class ClaudeConfig(BaseModel):
    saved: SavedUsage | None = Field(None, validation_alias="cachedUsageUtilization")


class OAuthToken(BaseModel):
    access_token: str = Field(validation_alias="accessToken")
    expires_at_ms: NonNegativeInt = Field(validation_alias="expiresAt")


class Credentials(BaseModel):
    oauth: OAuthToken = Field(validation_alias="claudeAiOauth")


@dataclass(frozen=True)
class SpendSnapshot:
    fetched_at: int  # Unix seconds
    spend: Spend


def claude_config_path(home: Path) -> Path:
    return home / ".claude.json"


def month_bounds(now: int) -> tuple[int, int]:
    """Return the current local month as Unix seconds, like Claude's own resets."""
    local = time.localtime(now)

    # With isdst=-1, mktime applies the offset in effect on each date, so a
    # daylight saving change inside the month does not shift the bounds. It
    # also rolls month 13 over into January.
    start = time.mktime((local.tm_year, local.tm_mon, 1, 0, 0, 0, 0, 0, -1))
    end = time.mktime((local.tm_year, local.tm_mon + 1, 1, 0, 0, 0, 0, 0, -1))
    return int(start), int(end)


class Keychain(Protocol):
    def read_credentials(self) -> str | None: ...


class UsageApi(Protocol):
    def get_usage(self, access_token: str) -> str | None: ...


class SpendSource(Protocol):
    def load(self, now: int) -> SpendSnapshot | None: ...


class SavedSpendSource:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self, now: int) -> SpendSnapshot | None:
        try:
            saved = ClaudeConfig.model_validate_json(self.path.read_text()).saved
        except (OSError, ValidationError):
            return None

        if saved is None:
            return None
        return SpendSnapshot(saved.fetched_at_ms // 1000, saved.usage.spend)


class LiveSpendSource:
    def __init__(self, keychain: Keychain, api: UsageApi, fallback: SpendSource) -> None:
        self.keychain = keychain
        self.api = api
        self.fallback = fallback

    def load(self, now: int) -> SpendSnapshot | None:
        return self.fetch(now) or self.fallback.load(now)

    def fetch(self, now: int) -> SpendSnapshot | None:
        token = self.access_token(now)
        if token is None:
            return None

        body = self.api.get_usage(token)
        if body is None:
            return None

        try:
            return SpendSnapshot(now, Usage.model_validate_json(body).spend)
        except ValidationError:
            return None

    def access_token(self, now: int) -> str | None:
        secret = self.keychain.read_credentials()
        if secret is None:
            return None

        try:
            token = Credentials.model_validate_json(secret).oauth
        except ValidationError:
            return None

        if token.expires_at_ms <= now * 1000:
            return None
        return token.access_token
