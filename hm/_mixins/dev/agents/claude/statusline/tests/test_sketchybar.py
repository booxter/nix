import io
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from claude_statusline.sketchybar import main
from claude_statusline.usage import FileUsageStore, RateLimits, RateWindow
from sketchybar_applet import SketchybarError

NOW = 1_767_225_600
ENVIRONMENT = {
    "SKETCHYBAR_BIN": "sketchybar",
    "SKETCHYBAR_COLOR_GREEN": "green",
    "SKETCHYBAR_COLOR_RED": "red",
    "SKETCHYBAR_COLOR_BLUE": "blue",
    "SKETCHYBAR_COLOR_NEUTRAL": "neutral",
}


@dataclass
class RecordingSketchybar:
    calls: list[list[str]] = field(default_factory=list)
    error: str | None = None

    def run(self, arguments: Sequence[str]) -> None:
        if self.error is not None:
            raise SketchybarError(self.error)
        self.calls.append(list(arguments))


def labels(bar: RecordingSketchybar) -> dict[str, tuple[str, str]]:
    """Map each item to its label and color from the last update."""
    [arguments] = bar.calls
    items: dict[str, tuple[str, str]] = {}
    item = ""
    settings: dict[str, str] = {}
    for argument in [*arguments, "--set"]:
        if argument == "--set":
            if item:
                items[item] = (settings.get("label", ""), settings.get("label.color", ""))
            item = ""
            settings = {}
        elif not item:
            item = argument
        else:
            key, _, value = argument.partition("=")
            settings[key] = value
    return items


def update(tmp_path: Path, limits: RateLimits | None) -> RecordingSketchybar:
    store = FileUsageStore(tmp_path / "rate-limits.json")
    if limits is not None:
        store.save(limits)
    bar = RecordingSketchybar()

    assert main(environment=ENVIRONMENT, store=store, bar=bar, now=NOW) == 0
    return bar


def test_shows_remaining_usage_and_pace(tmp_path: Path) -> None:
    limits = RateLimits(
        # Half the window left with only 10% used: well under pace.
        five_hour=RateWindow(used_percentage=10, resets_at=NOW + 9_000),
        # A day into the week with 60% used: far ahead of pace.
        seven_day=RateWindow(used_percentage=60, resets_at=NOW + 6 * 86_400),
    )

    bar = update(tmp_path, limits)

    assert labels(bar) == {
        "claude.5h": ("5h 90%/2h30", "green"),
        "claude.weekly": ("1w 40%/6d00h", "red"),
    }


def test_exhausted_window_is_red(tmp_path: Path) -> None:
    limits = RateLimits(five_hour=RateWindow(used_percentage=100, resets_at=NOW + 600))

    bar = update(tmp_path, limits)

    assert labels(bar)["claude.5h"] == ("5h 0%/10m", "red")


def test_reset_or_missing_windows_are_unknown(tmp_path: Path) -> None:
    limits = RateLimits(five_hour=RateWindow(used_percentage=80, resets_at=NOW))

    bar = update(tmp_path, limits)

    assert labels(bar) == {
        "claude.5h": ("5h ???", "blue"),
        "claude.weekly": ("1w ???", "blue"),
    }


def test_hides_until_the_status_line_saves_usage(tmp_path: Path) -> None:
    bar = update(tmp_path, None)

    assert bar.calls == [
        ["--set", "claude.5h", "drawing=off", "--set", "claude.weekly", "drawing=off"]
    ]


def test_sketchybar_failures_go_to_stderr(tmp_path: Path) -> None:
    stderr = io.StringIO()
    bar = RecordingSketchybar(error="SketchyBar exited with status 1")
    store = FileUsageStore(tmp_path / "missing.json")

    code = main(environment=ENVIRONMENT, store=store, bar=bar, now=NOW, stderr=stderr)
    missing_bin = main(environment={}, store=store, now=NOW, stderr=stderr)

    assert (code, missing_bin) == (1, 1)
    assert stderr.getvalue().splitlines() == [
        "claude-sketchybar: SketchyBar exited with status 1",
        "claude-sketchybar: missing environment setting SKETCHYBAR_BIN",
    ]
