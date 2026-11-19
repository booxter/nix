from __future__ import annotations

import os
import sys
import time
from collections.abc import Mapping, Sequence
from typing import Protocol, TextIO

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import UrllibJsonHttpClient
from codex_tools.sketchybar import Config
from codex_tools.usage import PersonalUsage, PersonalUsageService, ResetCredits, UsageWindow
from sketchybar_applet import (
    Colors,
    Sketchybar,
    SketchybarCommand,
    SketchybarError,
    format_duration,
    format_epoch_local,
    pace_color,
    rounded_risk_bps,
)

ITEM = "codex.personal"
RESETS_POPUP_ITEM = "codex.personal.resets"
EXPIRING_RESET_SECONDS = 604_800


class PersonalUsageProvider(Protocol):
    def fetch(self, auth: CodexAuth, *, now: float) -> PersonalUsage: ...


def format_window_label(name: str, window: UsageWindow) -> str:
    if window.remaining_percent is None or window.reset_after_seconds is None:
        return f"{name} ???"
    return f"{name} {window.remaining_percent}%/{format_duration(window.reset_after_seconds)}"


def window_pace_risk_bps(window: UsageWindow) -> int | None:
    if (
        window.used_percent is None
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
            ITEM,
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
            ITEM,
            "drawing=on",
            "label=err",
            f"label.color={config.colors.red}",
            "popup.drawing=off",
            "--set",
            RESETS_POPUP_ITEM,
            "drawing=off",
        ]
    )


def render_usage(config: Config, usage: PersonalUsage, bar: Sketchybar) -> None:
    labels: list[str] = []
    risks: list[int] = []
    reached = False
    windows = (("5h", "five_hour", usage.five_hour), ("1w", "weekly", usage.weekly))
    for name, kind, window in windows:
        if window is None:
            continue
        labels.append(format_window_label(name, window))
        risk = window_pace_risk_bps(window)
        if risk is not None:
            risks.append(risk)
        reached = reached or window_limit_reached(usage, kind)

    reset = usage.reset_credits
    labels.append(f"+{reset.available_count}")
    color = pace_color(max(risks, default=None), reached=reached, colors=config.colors)
    bar.run(
        [
            "--set",
            ITEM,
            "drawing=on",
            f"label={' · '.join(labels)}",
            f"label.color={color}",
            "popup.drawing=off",
            "--set",
            RESETS_POPUP_ITEM,
            "drawing=on",
            f"label={reset_tooltip(reset)}",
            f"label.color={reset_color(reset, config.colors)}",
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
            sketchybar.run(["--set", ITEM, "popup.drawing=on"])
            return 0
        if sender in {"mouse.exited", "mouse.exited.global"}:
            sketchybar.run(["--set", ITEM, "popup.drawing=off"])
            return 0
        update(
            config,
            service or PersonalUsageService(UrllibJsonHttpClient()),
            sketchybar,
            now=time.time() if now is None else now,
        )
    except (CodexToolsError, SketchybarError) as error:
        print(f"codex-sketchybar: {error}", file=stderr)
        return 1
    return 0
