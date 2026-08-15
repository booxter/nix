import io
import os
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path

import pytest

from codex_tools.errors import CodexToolsError
from codex_tools.sketchybar import Colors, Config
from codex_tools.sketchybar_work import (
    format_number,
    main,
    monthly_pace_risk_bps,
    render_usage,
)
from codex_tools.work_usage import WorkCredits, WorkUsage
from fakes import (
    FakeWorkUsageService,
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


def usage(
    *,
    reached: bool = False,
    remaining_percent: int | float | None = 75,
    reset_at: int | float | None = None,
) -> WorkUsage:
    return WorkUsage(
        account_id="account",
        email="user@example.com",
        plan_type="team",
        reached=reached,
        source="monthly",
        limit=1_000,
        used=249.96,
        remaining=750.04,
        used_percent=25,
        remaining_percent=remaining_percent,
        reset_after_seconds=90_000,
        reset_at=reset_at,
        window_start_at=0,
        window_seconds=100,
        elapsed_seconds=25,
        credits=WorkCredits(True, False, False, 12.5),
    )


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, "?"),
        (12.04, "12"),
        (12.05, "12.1"),
        (99.99, "100"),
        (100.4, "100"),
        (100.5, "101"),
    ],
)
def test_formats_credit_numbers(value: int | float | None, expected: str) -> None:
    assert format_number(value) == expected


def test_calculates_monthly_pace() -> None:
    assert monthly_pace_risk_bps(usage()) == 1_000
    assert monthly_pace_risk_bps(replace(usage(), used_percent=None)) is None
    assert monthly_pace_risk_bps(replace(usage(), window_seconds=None)) is None


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


def test_renders_credits_reset_and_limit_state() -> None:
    bar = RecordingSketchybar()
    with timezone("UTC"):
        render_usage(
            Config(Path("/auth"), COLORS, "/sketchybar"),
            usage(reached=True, reset_at=1_785_758_400),
            bar,
        )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.work"] == {
        "drawing": "on",
        "label": "work 75%",
        "label.color": "red",
        "popup.drawing": "off",
    }
    assert rendered["codex.work.credits"]["label"] == (
        "credits: 750/1000 left; used 250 (25%); limit reached"
    )
    assert rendered["codex.work.reset"]["label"] == ("reset: 2026-08-03 12:00 UTC (1d01h)")


@pytest.mark.parametrize(
    ("sender", "drawing"),
    [
        ("mouse.entered", "on"),
        ("mouse.exited", "off"),
        ("mouse.exited.global", "off"),
    ],
)
def test_handles_hover_without_fetching(sender: str, drawing: str) -> None:
    service = FakeWorkUsageService()
    bar = RecordingSketchybar()
    assert (
        main(
            service=service,
            bar=bar,
            environment={"SKETCHYBAR_BIN": "/sketchybar", "SENDER": sender},
        )
        == 0
    )
    assert sketchybar_properties(bar.calls[0])["codex.work"]["popup.drawing"] == drawing
    assert service.calls == []


def test_ignores_popup_item_updates() -> None:
    service = FakeWorkUsageService()
    bar = RecordingSketchybar()
    assert (
        main(
            service=service,
            bar=bar,
            environment={
                "SKETCHYBAR_BIN": "/sketchybar",
                "NAME": "codex.work.credits",
            },
        )
        == 0
    )
    assert bar.calls == []
    assert service.calls == []


def test_missing_auth_hides_items(tmp_path: Path) -> None:
    bar = RecordingSketchybar()
    assert (
        main(
            service=FakeWorkUsageService(),
            bar=bar,
            now=NOW,
            environment={"HOME": str(tmp_path), "SKETCHYBAR_BIN": "/sketchybar"},
        )
        == 0
    )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.work"]["drawing"] == "off"
    assert rendered["codex.work.credits"]["drawing"] == "off"
    assert rendered["codex.work.reset"]["drawing"] == "off"


def test_fetches_and_renders_work_usage(tmp_path: Path) -> None:
    write_codex_auth(tmp_path, account_id="account")
    service = FakeWorkUsageService(usage=usage())
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
    assert service.calls[0][0].account_id == "account"
    assert service.calls[0][1] == NOW
    assert sketchybar_properties(bar.calls[0])["codex.work"]["label"] == "work 75%"


def test_provider_failure_shows_error(tmp_path: Path) -> None:
    write_codex_auth(tmp_path, account_id="account")
    bar = RecordingSketchybar()
    assert (
        main(
            service=FakeWorkUsageService(error=CodexToolsError("unavailable")),
            bar=bar,
            now=NOW,
            environment={"HOME": str(tmp_path), "SKETCHYBAR_BIN": "/sketchybar"},
        )
        == 0
    )
    rendered = sketchybar_properties(bar.calls[0])
    assert rendered["codex.work"]["label"] == "work err"
    assert rendered["codex.work"]["label.color"] == "0xfffb4934"
    assert rendered["codex.work.credits"]["drawing"] == "off"


def test_reports_sketchybar_failure() -> None:
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
    assert stderr.getvalue() == "codex-work-sketchybar: unavailable\n"
