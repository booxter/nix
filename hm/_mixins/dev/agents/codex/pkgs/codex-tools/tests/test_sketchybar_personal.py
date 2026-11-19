import io
import os
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest
from codex_tools.errors import CodexToolsError
from codex_tools.sketchybar_personal import (
    Config,
    main,
    render_usage,
    reset_color,
    reset_tooltip,
    window_limit_reached,
    window_pace_risk_bps,
)
from codex_tools.usage import PersonalUsage, ResetCredit, ResetCredits, UsageWindow
from fakes import (
    FakePersonalUsageService,
    RecordingSketchybar,
    sketchybar_properties,
    write_codex_auth,
)
from sketchybar_applet import Colors, SketchybarError, format_epoch_local

NOW = 1_784_203_200
COLORS = Colors(
    green="green",
    red="red",
    blue="blue",
    neutral="neutral",
)


def window(
    *,
    used: int | float = 4,
    remaining: int = 96,
    length: int = 604_800,
    reset_after: int = 590_000,
) -> UsageWindow:
    return UsageWindow(
        used_percent=used,
        remaining_percent=remaining,
        limit_window_seconds=length,
        reset_after_seconds=reset_after,
        reset_at=None,
    )


def usage(
    *,
    five_hour: UsageWindow | None = None,
    weekly: UsageWindow | None = None,
    limit_reached: bool = False,
    limit_reached_type: str | None = None,
    resets: ResetCredits | None = None,
) -> PersonalUsage:
    return PersonalUsage(
        allowed=True,
        limit_reached=limit_reached,
        limit_reached_type=limit_reached_type,
        five_hour=five_hour,
        weekly=weekly,
        reset_credits=resets or ResetCredits(0, (), None),
    )


def test_calculates_pace_and_limit_state() -> None:
    exactly_on_pace = window(used=50, remaining=50, length=100, reset_after=50)
    assert window_pace_risk_bps(exactly_on_pace) == 1_000

    all_reached = usage(limit_reached=True, limit_reached_type="all")
    weekly_reached = usage(limit_reached=True, limit_reached_type="secondary")
    assert window_limit_reached(all_reached, "five_hour")
    assert window_limit_reached(all_reached, "weekly")
    assert not window_limit_reached(weekly_reached, "five_hour")
    assert window_limit_reached(weekly_reached, "weekly")


def test_renders_weekly_usage_without_a_five_hour_placeholder() -> None:
    bar = RecordingSketchybar()
    render_usage(
        Config(Path("/auth"), COLORS, "/sketchybar"),
        usage(weekly=window()),
        bar,
    )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.personal"]["drawing"] == "on"
    assert rendered["codex.personal"]["label"] == "1w 96%/6d19h · +0"
    assert rendered["codex.personal.resets"]["label"] == "No rate-limit reset credits available"


@contextmanager
def timezone(value: str) -> Iterator[None]:
    previous = os.environ.get("TZ")
    os.environ["TZ"] = value
    time.tzset()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time.tzset()


def test_formats_reset_expiry_in_local_time() -> None:
    credit = ResetCredit(
        expires_at="2026-08-03T12:00:00Z",
        expires_at_unix=1_785_758_400,
        expires_after_seconds=3_600,
    )
    with timezone("UTC"):
        assert format_epoch_local(credit.expires_at_unix) == "2026-08-03 12:00 UTC"
        assert reset_tooltip(ResetCredits(1, (credit,), credit)) == (
            "1 reset available; nearest expires 2026-08-03 12:00 UTC (1h00)"
        )
    assert reset_color(ResetCredits(1, (credit,), credit), COLORS) == "red"
    assert reset_color(ResetCredits(1, (), None), COLORS) == "green"
    assert reset_color(ResetCredits(0, (), None), COLORS) == "neutral"


@pytest.mark.parametrize(
    ("sender", "drawing"),
    [
        ("mouse.entered", "on"),
        ("mouse.exited", "off"),
        ("mouse.exited.global", "off"),
    ],
)
def test_handles_hover_without_fetching(sender: str, drawing: str) -> None:
    service = FakePersonalUsageService()
    bar = RecordingSketchybar()
    assert (
        main(
            service=service,
            bar=bar,
            environment={"SKETCHYBAR_BIN": "/sketchybar", "SENDER": sender},
        )
        == 0
    )
    assert sketchybar_properties(bar.calls[0])["codex.personal"]["popup.drawing"] == drawing
    assert service.calls == []


def test_missing_auth_hides_items(tmp_path: Path) -> None:
    bar = RecordingSketchybar()
    assert (
        main(
            service=FakePersonalUsageService(),
            bar=bar,
            now=NOW,
            environment={"HOME": str(tmp_path), "SKETCHYBAR_BIN": "/sketchybar"},
        )
        == 0
    )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.personal"]["drawing"] == "off"
    assert rendered["codex.personal"]["popup.drawing"] == "off"


def test_fetches_and_renders_usage(tmp_path: Path) -> None:
    write_codex_auth(tmp_path)
    service = FakePersonalUsageService(
        usage=usage(
            five_hour=window(length=18_000, reset_after=17_000),
            weekly=window(used=10, remaining=90),
            resets=ResetCredits(2, (), None),
        )
    )
    bar = RecordingSketchybar()
    assert (
        main(
            service=service,
            bar=bar,
            now=NOW,
            environment={"HOME": str(tmp_path), "SKETCHYBAR_BIN": "/sketchybar"},
        )
        == 0
    )
    assert service.calls[0][0].access_token == "token"
    assert service.calls[0][1] == NOW
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.personal"]["label"] == "5h 96%/4h43 · 1w 90%/6d19h · +2"
    assert rendered["codex.personal"]["label.color"] == "0xfffb4934"


def test_provider_failure_shows_error(tmp_path: Path) -> None:
    write_codex_auth(tmp_path)
    bar = RecordingSketchybar()
    assert (
        main(
            service=FakePersonalUsageService(error=CodexToolsError("unavailable")),
            bar=bar,
            now=NOW,
            environment={"HOME": str(tmp_path), "SKETCHYBAR_BIN": "/sketchybar"},
        )
        == 0
    )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.personal"]["label"] == "err"
    assert rendered["codex.personal"]["label.color"] == "0xfffb4934"
    assert rendered["codex.personal.resets"]["drawing"] == "off"


def test_reports_configuration_and_sketchybar_failures() -> None:
    stderr = io.StringIO()
    assert main(environment={}, stderr=stderr) == 1
    assert "missing environment setting SKETCHYBAR_BIN" in stderr.getvalue()

    stderr = io.StringIO()
    bar = RecordingSketchybar(error=SketchybarError("unavailable"))
    assert (
        main(
            bar=bar,
            environment={"SKETCHYBAR_BIN": "/sketchybar", "SENDER": "mouse.entered"},
            stderr=stderr,
        )
        == 1
    )
    assert stderr.getvalue() == "codex-sketchybar: unavailable\n"
