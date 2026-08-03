from __future__ import annotations

import math
import os
import sys
import time
from collections.abc import Mapping, Sequence
from typing import Protocol, TextIO

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import UrllibJsonHttpClient
from codex_tools.sketchybar import (
    Config,
    Sketchybar,
    SketchybarCommand,
    format_duration,
    format_epoch_local,
    pace_color,
    rounded_risk_bps,
)
from codex_tools.work_usage import WorkUsage, WorkUsageService

ITEM = "codex.work"
POPUP_CREDITS_ITEM = "codex.work.credits"
POPUP_RESET_ITEM = "codex.work.reset"


class WorkUsageProvider(Protocol):
    def fetch(self, auth: CodexAuth, *, now: float) -> WorkUsage: ...


def format_number(value: int | float | None) -> str:
    if value is None:
        return "?"
    if value < 0:
        return f"{value:g}" if isinstance(value, float) else str(value)
    if value >= 100:
        return str(math.floor(value + 0.5))
    return f"{math.floor(value * 10 + 0.5) / 10:g}"


def display_number(value: int | float | None) -> str:
    if value is None:
        return "?"
    return f"{value:g}" if isinstance(value, float) else str(value)


def monthly_pace_risk_bps(usage: WorkUsage) -> int | None:
    if usage.used_percent is None or usage.window_seconds is None:
        return None
    return rounded_risk_bps(
        usage.used_percent,
        usage.window_seconds,
        usage.elapsed_seconds,
    )


def hide_items(bar: Sketchybar) -> None:
    bar.run(
        [
            "--set",
            ITEM,
            "drawing=off",
            "popup.drawing=off",
            "--set",
            POPUP_CREDITS_ITEM,
            "drawing=off",
            "--set",
            POPUP_RESET_ITEM,
            "drawing=off",
        ]
    )


def show_error(config: Config, bar: Sketchybar) -> None:
    bar.run(
        [
            "--set",
            ITEM,
            "drawing=on",
            "icon.drawing=off",
            "label=work err",
            f"label.color={config.colors.red}",
            "popup.drawing=off",
            "--set",
            POPUP_CREDITS_ITEM,
            "drawing=off",
            "--set",
            POPUP_RESET_ITEM,
            "drawing=off",
        ]
    )


def render_usage(config: Config, usage: WorkUsage, bar: Sketchybar) -> None:
    credits_label = (
        f"credits: {format_number(usage.remaining)}/{format_number(usage.limit)} left; "
        f"used {format_number(usage.used)} ({display_number(usage.used_percent)}%)"
    )
    if usage.reached:
        credits_label += "; limit reached"

    reset_value = usage.reset_after_seconds
    reset_after = (
        int(reset_value)
        if isinstance(reset_value, (int, float)) and float(reset_value).is_integer()
        else None
    )
    reset_duration = format_duration(reset_after)
    reset_date = format_epoch_local(usage.reset_at)
    reset_label = (
        f"reset: {reset_date} ({reset_duration})"
        if reset_date is not None
        else f"reset: in {reset_duration}"
    )
    color = pace_color(
        monthly_pace_risk_bps(usage),
        reached=usage.reached,
        colors=config.colors,
    )
    bar.run(
        [
            "--set",
            ITEM,
            "drawing=on",
            f"label=work {display_number(usage.remaining_percent)}%",
            f"label.color={color}",
            "popup.drawing=off",
            "--set",
            POPUP_CREDITS_ITEM,
            "drawing=on",
            f"label={credits_label}",
            f"label.color={config.colors.neutral}",
            "--set",
            POPUP_RESET_ITEM,
            "drawing=on",
            f"label={reset_label}",
            f"label.color={config.colors.neutral}",
        ]
    )


def update(
    config: Config,
    service: WorkUsageProvider,
    bar: Sketchybar,
    *,
    now: float,
) -> None:
    if not config.auth_file.is_file():
        hide_items(bar)
        return
    try:
        usage = service.fetch(CodexAuth.load(config.auth_file), now=now)
    except CodexToolsError:
        show_error(config, bar)
        return
    render_usage(config, usage, bar)


def main(
    _argv: Sequence[str] | None = None,
    *,
    service: WorkUsageProvider | None = None,
    bar: Sketchybar | None = None,
    now: float | None = None,
    environment: Mapping[str, str] | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    settings = os.environ if environment is None else environment
    try:
        config = Config.from_environment(settings)
        sketchybar = bar or SketchybarCommand(config.sketchybar_executable)
        sender = settings.get("SENDER")
        if sender == "mouse.entered":
            sketchybar.run(["--set", ITEM, "popup.drawing=on"])
            return 0
        if sender in {"mouse.exited", "mouse.exited.global"}:
            sketchybar.run(["--set", ITEM, "popup.drawing=off"])
            return 0
        if settings.get("NAME") in {POPUP_CREDITS_ITEM, POPUP_RESET_ITEM}:
            return 0
        update(
            config,
            service or WorkUsageService(UrllibJsonHttpClient()),
            sketchybar,
            now=time.time() if now is None else now,
        )
    except CodexToolsError as error:
        print(f"codex-work-sketchybar: {error}", file=stderr)
        return 1
    return 0
