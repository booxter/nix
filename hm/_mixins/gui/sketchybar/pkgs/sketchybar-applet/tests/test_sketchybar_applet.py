import os
import stat
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest
from sketchybar_applet import (
    Colors,
    SketchybarCommand,
    SketchybarError,
    format_duration,
    format_epoch_local,
    gradient_color,
    pace_color,
    rounded_risk_bps,
    sketchybar_executable,
)

COLORS = Colors(green="green", red="red", blue="blue", neutral="neutral")


def write_executable(path: Path, script: str) -> str:
    path.write_text(f"#!/bin/sh\n{script}\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


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


def test_colors_default_and_environment_overrides() -> None:
    defaults = Colors.from_environment({})
    assert defaults.green == "0xffb8bb26"
    assert defaults.red == "0xfffb4934"
    assert defaults.blue == "0xff83a598"
    assert defaults.neutral == "0xffd5c4a1"

    overridden = Colors.from_environment({"SKETCHYBAR_COLOR_RED": "0xff000000"})
    assert overridden.red == "0xff000000"
    assert overridden.green == defaults.green


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (None, "?"),
        (-1, "expired"),
        (0, "0s"),
        (59, "59s"),
        (60, "1m"),
        (3_599, "59m"),
        (3_661, "1h01"),
        (86_399, "23h59"),
        (90_000, "1d01h"),
    ],
)
def test_formats_compact_durations(seconds: int | None, expected: str) -> None:
    assert format_duration(seconds) == expected


def test_formats_epoch_in_local_time() -> None:
    with timezone("UTC"):
        assert format_epoch_local(1_785_758_400) == "2026-08-03 12:00 UTC"
        assert format_epoch_local(None) is None
        assert format_epoch_local(float("inf")) is None


@pytest.mark.parametrize(
    ("risk_bps", "expected"),
    [
        (None, "blue"),
        (0, "green"),
        (1_000, "green"),
        (1_050, "0xffbfbf69"),
        (1_100, "0xffe0af68"),
        (1_250, "0xffff9e64"),
        (1_500, "0xfff7768e"),
        (1_501, "red"),
    ],
)
def test_gradient_color_follows_risk_thresholds(risk_bps: int | None, expected: str) -> None:
    assert gradient_color(risk_bps, COLORS) == expected


def test_pace_color_is_red_once_limit_is_reached() -> None:
    assert pace_color(0, reached=True, colors=COLORS) == "red"
    assert pace_color(0, reached=False, colors=COLORS) == "green"
    assert pace_color(None, reached=False, colors=COLORS) == "blue"


@pytest.mark.parametrize(
    ("used", "window", "elapsed", "expected"),
    [
        (0, 100, 50, 0),
        (-5, 100, 50, 0),
        (50, 100, 50, 1_000),
        (4, 604_800, 14_800, 1_635),
        (10, 0, 50, None),
        (10, 100, 0, None),
    ],
)
def test_rounds_risk_in_basis_points(
    used: int,
    window: int,
    elapsed: int,
    expected: int | None,
) -> None:
    assert rounded_risk_bps(used, window, elapsed) == expected


def test_reads_executable_from_environment() -> None:
    assert sketchybar_executable({"SKETCHYBAR_BIN": "/bin/sketchybar"}) == "/bin/sketchybar"


@pytest.mark.parametrize("environment", [{}, {"SKETCHYBAR_BIN": ""}])
def test_requires_executable_setting(environment: dict[str, str]) -> None:
    with pytest.raises(SketchybarError, match="missing environment setting SKETCHYBAR_BIN"):
        sketchybar_executable(environment)


def test_command_passes_arguments_to_executable(tmp_path: Path) -> None:
    record = tmp_path / "arguments"
    executable = write_executable(tmp_path / "sketchybar", f'printf "%s\\n" "$@" > "{record}"')

    SketchybarCommand(executable).run(["--set", "item", "label=hello world"])

    assert record.read_text().splitlines() == ["--set", "item", "label=hello world"]


def test_command_reports_missing_executable(tmp_path: Path) -> None:
    with pytest.raises(SketchybarError, match="Cannot run SketchyBar"):
        SketchybarCommand(str(tmp_path / "missing")).run([])


def test_command_reports_exit_status_without_output(tmp_path: Path) -> None:
    executable = write_executable(tmp_path / "sketchybar", "exit 3")

    with pytest.raises(SketchybarError) as error:
        SketchybarCommand(executable).run([])

    assert str(error.value) == "SketchyBar exited with status 3"


def test_command_reports_exit_status_with_error_output(tmp_path: Path) -> None:
    executable = write_executable(tmp_path / "sketchybar", "echo 'no such item' >&2; exit 1")

    with pytest.raises(SketchybarError) as error:
        SketchybarCommand(executable).run([])

    assert str(error.value) == "SketchyBar exited with status 1: no such item"
