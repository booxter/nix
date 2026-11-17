import io
import json
import time
from collections.abc import Iterator
from pathlib import Path

import pytest
from claude_statusline.sketchybar_work import main
from fakes import ENVIRONMENT, RecordingSketchybar, labels

NOW = 1_794_848_400  # 2026-11-16 12:00 in New York, mid-month
LAST_OCTOBER_EVENING = 1_793_502_000  # 2026-10-31 23:00 in New York


@pytest.fixture(autouse=True)
def new_york(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    # Claude resets monthly spend at local midnight on the 1st. A POSIX rule
    # for New York works without the zone database the build sandbox lacks.
    monkeypatch.setenv("TZ", "EST5EDT,M3.2.0,M11.1.0")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def write_claude_config(home: Path, extra_usage: object, fetched_at: int = NOW - 300) -> None:
    saved = {
        "fetchedAtMs": fetched_at * 1000,
        "utilization": {"five_hour": None, "extra_usage": extra_usage, "limits": []},
    }
    config = {"numStartups": 3, "cachedUsageUtilization": saved}
    (home / ".claude.json").write_text(json.dumps(config))


def spend(used_cents: int) -> dict[str, object]:
    return {
        "is_enabled": True,
        "monthly_limit": 1_000_000,
        "used_credits": used_cents,
        "utilization": None,
        "currency": "USD",
        "decimal_places": 2,
    }


def update(home: Path, sender: str | None = None, now: int = NOW) -> RecordingSketchybar:
    environment = {**ENVIRONMENT, "HOME": str(home)}
    if sender is not None:
        environment["SENDER"] = sender
    bar = RecordingSketchybar()

    assert main(environment=environment, bar=bar, now=now) == 0
    return bar


def test_shows_remaining_spend_with_details(tmp_path: Path) -> None:
    write_claude_config(tmp_path, spend(1_228))

    bar = update(tmp_path)

    assert labels(bar) == {
        "claude.work": ("99.9%", "green"),
        "claude.work.spend": ("spent: 12.28 USD of 10,000.00 USD; updated 5m ago", "neutral"),
        "claude.work.reset": ("reset: Dec 1", "neutral"),
    }


def test_spending_ahead_of_the_month_is_red(tmp_path: Path) -> None:
    # Half the month has passed with 80% of the limit spent.
    write_claude_config(tmp_path, spend(800_000))

    bar = update(tmp_path)

    assert labels(bar)["claude.work"] == ("20.0%", "red")


def test_reached_limit_is_red(tmp_path: Path) -> None:
    write_claude_config(tmp_path, spend(1_000_050))

    bar = update(tmp_path)

    assert labels(bar)["claude.work"] == ("0.0%", "red")


def test_december_resets_in_the_new_year(tmp_path: Path) -> None:
    december = NOW + 30 * 86_400
    write_claude_config(tmp_path, spend(1_228), fetched_at=december)

    bar = update(tmp_path, now=december)

    assert labels(bar)["claude.work.reset"][0] == "reset: Jan 1"


def test_spend_saved_last_month_is_unknown(tmp_path: Path) -> None:
    write_claude_config(tmp_path, spend(900_000), fetched_at=LAST_OCTOBER_EVENING)

    bar = update(tmp_path)

    assert labels(bar)["claude.work"] == ("???", "blue")
    assert labels(bar)["claude.work.spend"][0] == (
        "spent: unknown since the reset; updated 15d14h ago"
    )


@pytest.mark.parametrize("extra_usage", [None, {**spend(0), "monthly_limit": None}])
def test_hides_without_monthly_spend(tmp_path: Path, extra_usage: object) -> None:
    write_claude_config(tmp_path, extra_usage)

    bar = update(tmp_path)

    assert bar.calls == [["--set", "claude.work", "drawing=off", "popup.drawing=off"]]


def test_hides_without_claude_config(tmp_path: Path) -> None:
    bar = update(tmp_path)

    assert bar.calls == [["--set", "claude.work", "drawing=off", "popup.drawing=off"]]


def test_hover_toggles_details(tmp_path: Path) -> None:
    entered = update(tmp_path, "mouse.entered")
    exited = update(tmp_path, "mouse.exited")

    assert entered.calls == [["--set", "claude.work", "popup.drawing=on"]]
    assert exited.calls == [["--set", "claude.work", "popup.drawing=off"]]


def test_sketchybar_failures_go_to_stderr(tmp_path: Path) -> None:
    stderr = io.StringIO()
    bar = RecordingSketchybar(error="SketchyBar exited with status 1")
    environment = {**ENVIRONMENT, "HOME": str(tmp_path)}

    code = main(environment=environment, bar=bar, now=NOW, stderr=stderr)

    assert code == 1
    assert stderr.getvalue() == "claude-work-sketchybar: SketchyBar exited with status 1\n"
