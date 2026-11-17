"""SketchyBar applet for the Claude subscription usage the status line saves.

See claude_statusline.usage for why the data comes from the status line and how
that limits its freshness.
"""

import os
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import TextIO

from claude_statusline.usage import (
    FileUsageStore,
    RateLimits,
    RateWindow,
    UsageStore,
    rate_limits_path,
)
from sketchybar_applet import (
    Colors,
    Sketchybar,
    SketchybarCommand,
    SketchybarError,
    format_duration,
    pace_color,
    rounded_risk_bps,
    sketchybar_executable,
)

FIVE_HOUR_ITEM = "claude.5h"
WEEKLY_ITEM = "claude.weekly"
FIVE_HOURS = 5 * 3_600
ONE_WEEK = 7 * 86_400


def current(window: RateWindow | None, now: int) -> RateWindow | None:
    # Once a window resets, the saved usage no longer applies, and the new
    # usage is unknown until a Claude session refreshes it.
    if window is None or window.resets_at <= now:
        return None
    return window


def window_label(name: str, window: RateWindow | None, now: int) -> str:
    window = current(window, now)
    if window is None:
        return f"{name} ???"

    remaining = max(0, int(100 - window.used_percentage))
    return f"{name} {remaining}%/{format_duration(window.resets_at - now)}"


def window_color(window: RateWindow | None, length: int, now: int, colors: Colors) -> str:
    window = current(window, now)
    if window is None:
        return pace_color(None, reached=False, colors=colors)

    elapsed = length - (window.resets_at - now)
    risk = rounded_risk_bps(window.used_percentage, length, elapsed)
    return pace_color(risk, reached=window.used_percentage >= 100, colors=colors)


def item_arguments(
    item: str, name: str, window: RateWindow | None, length: int, now: int, colors: Colors
) -> list[str]:
    return [
        "--set",
        item,
        "drawing=on",
        f"label={window_label(name, window, now)}",
        f"label.color={window_color(window, length, now, colors)}",
    ]


def render(limits: RateLimits, now: int, colors: Colors) -> list[str]:
    return [
        *item_arguments(FIVE_HOUR_ITEM, "5h", limits.five_hour, FIVE_HOURS, now, colors),
        *item_arguments(WEEKLY_ITEM, "1w", limits.seven_day, ONE_WEEK, now, colors),
    ]


def update(store: UsageStore, bar: Sketchybar, now: int, colors: Colors) -> None:
    limits = store.load()
    if limits is None:
        bar.run(["--set", FIVE_HOUR_ITEM, "drawing=off", "--set", WEEKLY_ITEM, "drawing=off"])
        return

    bar.run(render(limits, now, colors))


def main(
    *,
    environment: Mapping[str, str] | None = None,
    store: UsageStore | None = None,
    bar: Sketchybar | None = None,
    now: int | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    settings = os.environ if environment is None else environment
    try:
        home = Path(settings.get("HOME", str(Path.home())))
        update(
            store or FileUsageStore(rate_limits_path(home)),
            bar or SketchybarCommand(sketchybar_executable(settings)),
            int(time.time()) if now is None else now,
            Colors.from_environment(settings),
        )
    except SketchybarError as error:
        print(f"claude-sketchybar: {error}", file=stderr)
        return 1
    return 0
