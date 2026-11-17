"""Read the monthly spend of a Claude Enterprise seat billed by usage.

Such seats have no 5-hour or 7-day windows, so the status line never receives
rate limits. Instead, Claude Code saves its last usage API response in
~/.claude.json, including the seat's monthly spend and limit. Claude Code
refreshes that copy only now and then (for example, when /usage runs), so it
can lag behind the real spend; the applet shows its age.
"""

import time
from pathlib import Path
from typing import Protocol

from pydantic import AliasPath, BaseModel, Field, NonNegativeInt, PositiveInt, ValidationError


class Spend(BaseModel):
    """Spend in minor currency units, for example cents for USD."""

    used: NonNegativeInt = Field(validation_alias="used_credits")
    limit: PositiveInt = Field(validation_alias="monthly_limit")
    currency: str
    decimal_places: NonNegativeInt

    def format(self, amount: int) -> str:
        value = amount / 10**self.decimal_places
        return f"{value:,.{self.decimal_places}f} {self.currency}"


class SavedSpend(BaseModel):
    fetched_at_ms: NonNegativeInt = Field(validation_alias="fetchedAtMs")
    spend: Spend = Field(validation_alias=AliasPath("utilization", "extra_usage"))

    @property
    def fetched_at(self) -> int:
        return self.fetched_at_ms // 1000


class ClaudeConfig(BaseModel):
    saved: SavedSpend | None = Field(None, validation_alias="cachedUsageUtilization")


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


class SpendStore(Protocol):
    def load(self) -> SavedSpend | None: ...


class ClaudeConfigSpendStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> SavedSpend | None:
        try:
            return ClaudeConfig.model_validate_json(self.path.read_text()).saved
        except (OSError, ValidationError):
            return None
