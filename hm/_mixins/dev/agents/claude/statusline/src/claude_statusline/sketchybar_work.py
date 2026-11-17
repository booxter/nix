"""SketchyBar applet for the monthly spend of a Claude Enterprise seat.

See claude_statusline.spend for where the spend comes from and how fresh it is.
"""

import os
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import TextIO

from claude_statusline.account import SecurityKeychain, UrllibUsageApi
from claude_statusline.spend import (
    LiveSpendSource,
    SavedSpendSource,
    SpendSnapshot,
    SpendSource,
    claude_config_path,
    month_bounds,
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

ITEM = "claude.work"
POPUP_SPEND_ITEM = "claude.work.spend"
POPUP_RESET_ITEM = "claude.work.reset"


def format_day(epoch: int) -> str:
    day = time.localtime(epoch)
    return f"{time.strftime('%b', day)} {day.tm_mday}"


def spend_arguments(snapshot: SpendSnapshot, now: int, colors: Colors) -> list[str]:
    start, end = month_bounds(now)
    updated = f"updated {format_duration(now - snapshot.fetched_at)} ago"

    # Spend fetched before the month reset belongs to the previous month.
    if snapshot.fetched_at < start:
        label, color = "???", pace_color(None, reached=False, colors=colors)
        spend = f"spent: unknown since the reset; {updated}"
    else:
        used = snapshot.spend.used * 100 / snapshot.spend.limit
        risk = rounded_risk_bps(used, end - start, now - start)
        label = f"{max(0.0, 100 - used):.1f}%"
        color = pace_color(risk, reached=used >= 100, colors=colors)
        spend = (
            f"spent: {snapshot.spend.format(snapshot.spend.used)} "
            f"of {snapshot.spend.format(snapshot.spend.limit)}; {updated}"
        )

    return [
        "--set",
        ITEM,
        "drawing=on",
        f"label={label}",
        f"label.color={color}",
        "--set",
        POPUP_SPEND_ITEM,
        "drawing=on",
        f"label={spend}",
        f"label.color={colors.neutral}",
        "--set",
        POPUP_RESET_ITEM,
        "drawing=on",
        f"label=reset: {format_day(end)}",
        f"label.color={colors.neutral}",
    ]


def update(source: SpendSource, bar: Sketchybar, now: int, colors: Colors) -> None:
    snapshot = source.load(now)
    if snapshot is None:
        bar.run(["--set", ITEM, "drawing=off", "popup.drawing=off"])
        return

    bar.run(spend_arguments(snapshot, now, colors))


def default_source(home: Path) -> SpendSource:
    saved = SavedSpendSource(claude_config_path(home))
    return LiveSpendSource(SecurityKeychain(), UrllibUsageApi(), fallback=saved)


def main(
    *,
    environment: Mapping[str, str] | None = None,
    source: SpendSource | None = None,
    bar: Sketchybar | None = None,
    now: int | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    settings = os.environ if environment is None else environment
    try:
        sketchybar = bar or SketchybarCommand(sketchybar_executable(settings))
        sender = settings.get("SENDER")
        if sender == "mouse.entered":
            sketchybar.run(["--set", ITEM, "popup.drawing=on"])
            return 0
        if sender in {"mouse.exited", "mouse.exited.global"}:
            sketchybar.run(["--set", ITEM, "popup.drawing=off"])
            return 0

        home = Path(settings.get("HOME", str(Path.home())))
        update(
            source or default_source(home),
            sketchybar,
            int(time.time()) if now is None else now,
            Colors.from_environment(settings),
        )
    except SketchybarError as error:
        print(f"claude-work-sketchybar: {error}", file=stderr)
        return 1
    return 0
