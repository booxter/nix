import io
import os
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

from codex_tools.errors import CodexToolsError
from codex_tools.sketchybar import (
    Colors,
    format_duration,
    format_epoch_local,
    gradient_color,
    pace_color,
)
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


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (None, "?"),
        (-1, "expired"),
        (59, "59s"),
        (60, "1m"),
        (3_661, "1h01"),
        (90_000, "1d01h"),
    ],
)
def test_formats_compact_durations(seconds: int | None, expected: str) -> None:
    assert format_duration(seconds) == expected


def test_calculates_pace_and_limit_colors() -> None:
    exactly_on_pace = window(used=50, remaining=50, length=100, reset_after=50)
    assert window_pace_risk_bps(exactly_on_pace) == 1_000
    assert pace_color(1_000, reached=False, colors=COLORS) == "green"
    assert pace_color(None, reached=False, colors=COLORS) == "blue"
    assert pace_color(1_501, reached=False, colors=COLORS) == "red"
    assert gradient_color(1_100, COLORS) == "0xffe0af68"
    assert gradient_color(1_250, COLORS) == "0xffff9e64"
    assert gradient_color(1_500, COLORS) == "0xfff7768e"

    all_reached = usage(limit_reached=True, limit_reached_type="all")
    weekly_reached = usage(limit_reached=True, limit_reached_type="secondary")
    assert window_limit_reached(all_reached, "five_hour")
    assert window_limit_reached(all_reached, "weekly")
    assert not window_limit_reached(weekly_reached, "five_hour")
    assert window_limit_reached(weekly_reached, "weekly")


def test_renders_unavailable_window_with_compact_placeholder() -> None:
    bar = RecordingSketchybar()
    render_usage(
        Config(Path("/auth"), COLORS, "/sketchybar"),
        usage(weekly=window()),
        bar,
    )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.5h"]["label"] == "5h ???"
    assert rendered["codex.weekly"]["label"] == "1w 96%/6d19h"
    assert rendered["codex.resets"]["label"] == "+0"
    assert rendered["codex.resets.expiry"]["label"] == ("No rate-limit reset credits available")


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
    assert sketchybar_properties(bar.calls[0])["codex.resets"]["popup.drawing"] == drawing
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
    assert rendered["codex.5h"]["drawing"] == "off"
    assert rendered["codex.weekly"]["drawing"] == "off"
    assert rendered["codex.resets"]["popup.drawing"] == "off"


def test_fetches_and_renders_usage(tmp_path: Path) -> None:
    write_codex_auth(tmp_path)
    service = FakePersonalUsageService(
        usage=usage(five_hour=window(length=18_000, reset_after=17_000))
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
    assert sketchybar_properties(bar.calls[0])["codex.5h"]["label"] == "5h 96%/4h43"


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
    assert rendered["codex.5h"]["label"] == "err"
    assert rendered["codex.5h"]["label.color"] == "0xfffb4934"
    assert rendered["codex.weekly"]["drawing"] == "off"


def test_reports_configuration_and_sketchybar_failures() -> None:
    stderr = io.StringIO()
    assert main(environment={}, stderr=stderr) == 1
    assert "missing environment setting SKETCHYBAR_BIN" in stderr.getvalue()

    stderr = io.StringIO()
    bar = RecordingSketchybar(error=CodexToolsError("unavailable"))
    assert (
        main(
            bar=bar,
            environment={"SKETCHYBAR_BIN": "/sketchybar", "SENDER": "mouse.entered"},
            stderr=stderr,
        )
        == 1
    )
    assert stderr.getvalue() == "codex-sketchybar: unavailable\n"
