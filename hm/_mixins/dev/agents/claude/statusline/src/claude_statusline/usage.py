"""Share Claude subscription usage from the status line with other local tools.

Claude Code passes the account's rate limits to the status line, so the status
line saves them for the SketchyBar applet instead of the applet calling Claude's
internal usage API with Claude's credentials. This has limitations:

- Values refresh only while a Claude Code session runs its status line.
- Usage from claude.ai, the desktop app, or other machines shows up only after
  the next status line refresh here.
- Claude Code sends rate limits only for claude.ai subscriptions; other
  accounts never produce this file.
"""

from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from pydantic import BaseModel, NonNegativeInt, ValidationError


class RateWindow(BaseModel):
    used_percentage: float
    resets_at: NonNegativeInt  # Unix seconds


class RateLimits(BaseModel):
    five_hour: RateWindow | None = None
    seven_day: RateWindow | None = None


def rate_limits_path(home: Path) -> Path:
    return home / ".cache" / "claude-statusline" / "rate-limits.json"


class UsageStore(Protocol):
    def save(self, limits: RateLimits) -> None: ...

    def load(self) -> RateLimits | None: ...


class FileUsageStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def save(self, limits: RateLimits) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        write_text_atomic(self.path, limits.model_dump_json())

    def load(self) -> RateLimits | None:
        try:
            return RateLimits.model_validate_json(self.path.read_text())
        except (OSError, ValidationError):
            return None
