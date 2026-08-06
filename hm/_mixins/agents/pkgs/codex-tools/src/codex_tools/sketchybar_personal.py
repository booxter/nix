from __future__ import annotations

import os
import sys
import time
from collections.abc import Mapping, Sequence
from typing import Protocol, TextIO

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import UrllibJsonHttpClient
from codex_tools.sketchybar import (
    Colors,
    Config,
    Sketchybar,
    SketchybarCommand,
    format_duration,
    format_epoch_local,
    pace_color,
    rounded_risk_bps,
)
from codex_tools.usage import PersonalUsage, PersonalUsageService, ResetCredits, UsageWindow

FIVE_HOUR_ITEM = "codex.5h"
WEEKLY_ITEM = "codex.weekly"
RESETS_ITEM = "codex.resets"
RESETS_POPUP_ITEM = "codex.resets.expiry"
EXPIRING_RESET_SECONDS = 604_800


class PersonalUsageProvider(Protocol):
    def fetch(self, auth: CodexAuth, *, now: float) -> PersonalUsage: ...


def format_window_label(name: str, window: UsageWindow | None) -> str:
    if window is None or window.remaining_percent is None or window.reset_after_seconds is None:
        return f"{name} ???"
    return f"{name} {window.remaining_percent}%/{format_duration(window.reset_after_seconds)}"


def window_pace_risk_bps(window: UsageWindow | None) -> int | None:
    if (
        window is None
        or window.used_percent is None
        or window.limit_window_seconds is None
        or window.reset_after_seconds is None
    ):
        return None
    return rounded_risk_bps(
        window.used_percent,
        window.limit_window_seconds,
        window.limit_window_seconds - window.reset_after_seconds,
    )


def window_limit_reached(usage: PersonalUsage, window: str) -> bool:
    if usage.limit_reached is not True:
        return False
    reached_type = usage.limit_reached_type
    if reached_type in {None, "", "all", "both"}:
        return True
    if window == "five_hour":
        return reached_type in {"primary", "primary_window", "five_hour"}
    return reached_type in {"secondary", "secondary_window", "weekly"}


def reset_color(reset: ResetCredits, colors: Colors) -> str:
    if reset.available_count <= 0:
        return colors.neutral
    expires_after = reset.next_credit.expires_after_seconds if reset.next_credit else None
    if expires_after is not None and expires_after <= EXPIRING_RESET_SECONDS:
        return colors.red
    return colors.green


def reset_tooltip(reset: ResetCredits) -> str:
    count = reset.available_count
    if count <= 0:
        return "No rate-limit reset credits available"
    count_text = f"{count} reset" if count == 1 else f"{count} resets"
    credit = reset.next_credit
    if credit is None:
        return f"{count_text} available; expiry unavailable"
    remaining = format_duration(credit.expires_after_seconds)
    expires = format_epoch_local(credit.expires_at_unix) or credit.expires_at
    if not expires:
        return f"{count_text} available; expiry unavailable"
    return f"{count_text} available; nearest expires {expires} ({remaining})"


def hide_items(bar: Sketchybar) -> None:
    bar.run(
        [
            "--set",
            FIVE_HOUR_ITEM,
            "drawing=off",
            "--set",
            WEEKLY_ITEM,
            "drawing=off",
            "--set",
            RESETS_ITEM,
            "drawing=off",
            "popup.drawing=off",
            "--set",
            RESETS_POPUP_ITEM,
            "drawing=off",
        ]
    )


def show_error(config: Config, bar: Sketchybar) -> None:
    bar.run(
        [
            "--set",
            FIVE_HOUR_ITEM,
            "drawing=on",
            "icon.drawing=off",
            "label=err",
            f"label.color={config.colors.red}",
            "--set",
            WEEKLY_ITEM,
            "drawing=off",
            "--set",
            RESETS_ITEM,
            "drawing=off",
            "popup.drawing=off",
            "--set",
            RESETS_POPUP_ITEM,
            "drawing=off",
        ]
    )


def render_usage(config: Config, usage: PersonalUsage, bar: Sketchybar) -> None:
    five_color = pace_color(
        window_pace_risk_bps(usage.five_hour),
        reached=window_limit_reached(usage, "five_hour"),
        colors=config.colors,
    )
    weekly_color = pace_color(
        window_pace_risk_bps(usage.weekly),
        reached=window_limit_reached(usage, "weekly"),
        colors=config.colors,
    )
    credits_color = reset_color(usage.reset_credits, config.colors)
    bar.run(
        [
            "--set",
            FIVE_HOUR_ITEM,
            "drawing=on",
            f"label={format_window_label('5h', usage.five_hour)}",
            f"label.color={five_color}",
            "--set",
            WEEKLY_ITEM,
            "drawing=on",
            f"label={format_window_label('1w', usage.weekly)}",
            f"label.color={weekly_color}",
            "--set",
            RESETS_ITEM,
            "drawing=on",
            f"label=+{usage.reset_credits.available_count}",
            f"label.color={credits_color}",
            "popup.drawing=off",
            "--set",
            RESETS_POPUP_ITEM,
            "drawing=on",
            f"label={reset_tooltip(usage.reset_credits)}",
            f"label.color={credits_color}",
        ]
    )


def update(
    config: Config,
    service: PersonalUsageProvider,
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
    service: PersonalUsageProvider | None = None,
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
            sketchybar.run(["--set", RESETS_ITEM, "popup.drawing=on"])
            return 0
        if sender in {"mouse.exited", "mouse.exited.global"}:
            sketchybar.run(["--set", RESETS_ITEM, "popup.drawing=off"])
            return 0
        if settings.get("NAME") == RESETS_ITEM:
            return 0
        update(
            config,
            service or PersonalUsageService(UrllibJsonHttpClient()),
            sketchybar,
            now=time.time() if now is None else now,
        )
    except CodexToolsError as error:
        print(f"codex-sketchybar: {error}", file=stderr)
        return 1
    return 0
