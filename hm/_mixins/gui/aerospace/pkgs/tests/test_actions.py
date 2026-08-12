import io
from collections.abc import Callable
from pathlib import Path

import pytest

from aerospace_x11.cli import move, resize
from aerospace_x11.service import Direction, display_names, moved_position, resized_dimensions


class FixedFrontmostApplication:
    def __init__(self, bundle_identifier: str | None) -> None:
        self.value = bundle_identifier

    def bundle_identifier(self) -> str | None:
        return self.value


class RecordingAerospace:
    def __init__(self, status: int = 0) -> None:
        self.status = status
        self.actions: list[tuple[str, str | int]] = []

    def move(self, direction: Direction) -> int:
        self.actions.append(("move", direction))
        return self.status

    def resize(self, delta: int) -> int:
        self.actions.append(("resize", delta))
        return self.status


class RecordingX11Windows:
    def __init__(self, successful_display: str | None = None) -> None:
        self.successful_display = successful_display
        self.actions: list[tuple[str, str, Direction | int]] = []

    def move_active(self, display: str, direction: Direction) -> bool:
        self.actions.append(("move", display, direction))
        return display == self.successful_display

    def resize_active(self, display: str, delta: int) -> bool:
        self.actions.append(("resize", display, delta))
        return display == self.successful_display


def test_discovers_and_deduplicates_candidate_displays(tmp_path: Path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    (first / "X7").touch()
    (second / "X8").touch()

    displays = display_names(
        {"XQUARTZ_DISPLAY": ":7", "DISPLAY": ":2"},
        (first, second),
    )

    assert displays[:4] == (":7", ":2", ":8", ":0")
    assert displays.count(":7") == 1
    assert displays[-1] == ":9"


@pytest.mark.parametrize(
    ("position", "direction", "expected"),
    [
        ((20, 30), Direction.LEFT, (0, 30)),
        ((20, 30), Direction.RIGHT, (70, 30)),
        ((20, 30), Direction.UP, (20, 0)),
        ((20, 30), Direction.DOWN, (20, 80)),
    ],
)
def test_calculates_bounded_window_positions(
    position: tuple[int, int],
    direction: Direction,
    expected: tuple[int, int],
) -> None:
    assert moved_position(*position, direction) == expected


def test_calculates_bounded_window_dimensions() -> None:
    assert resized_dimensions(100, 80, 25) == (125, 105)
    assert resized_dimensions(100, 80, -75) == (50, 50)


def test_routes_non_x11_actions_to_aerospace() -> None:
    aerospace = RecordingAerospace(status=5)
    x11 = RecordingX11Windows()
    frontmost = FixedFrontmostApplication("com.apple.Terminal")

    move_status = move(
        ["left"],
        environment={},
        frontmost=frontmost,
        x11=x11,
        aerospace=aerospace,
    )
    resize_status = resize(
        ["+50"],
        environment={},
        frontmost=frontmost,
        x11=x11,
        aerospace=aerospace,
    )

    assert move_status == 5
    assert resize_status == 5
    assert aerospace.actions == [("move", Direction.LEFT), ("resize", 50)]
    assert x11.actions == []


@pytest.mark.parametrize("bundle_identifier", ["org.nixos.xquartz.X11", "org.x.X11"])
def test_routes_xquartz_actions_to_the_first_active_display(bundle_identifier: str) -> None:
    aerospace = RecordingAerospace()
    x11 = RecordingX11Windows(successful_display=":2")
    frontmost = FixedFrontmostApplication(bundle_identifier)

    status = move(
        ["right"],
        environment={"XQUARTZ_DISPLAY": ":7", "DISPLAY": ":2"},
        frontmost=frontmost,
        x11=x11,
        aerospace=aerospace,
    )

    assert status == 0
    assert x11.actions == [
        ("move", ":7", Direction.RIGHT),
        ("move", ":2", Direction.RIGHT),
    ]
    assert aerospace.actions == []


def test_routes_xquartz_resize_to_the_active_display() -> None:
    x11 = RecordingX11Windows(successful_display=":4")

    status = resize(
        ["-50"],
        environment={"DISPLAY": ":4"},
        frontmost=FixedFrontmostApplication("org.nixos.xquartz.X11"),
        x11=x11,
        aerospace=RecordingAerospace(),
    )

    assert status == 0
    assert x11.actions == [("resize", ":4", -50)]


def test_reports_missing_frontmost_application_and_x11_window() -> None:
    aerospace = RecordingAerospace()
    stderr = io.StringIO()

    unknown_status = resize(
        ["-50"],
        environment={},
        frontmost=FixedFrontmostApplication(None),
        x11=RecordingX11Windows(),
        aerospace=aerospace,
        stderr=stderr,
    )
    missing_status = move(
        ["up"],
        environment={"DISPLAY": ":4"},
        frontmost=FixedFrontmostApplication("org.nixos.xquartz.X11"),
        x11=RecordingX11Windows(),
        aerospace=aerospace,
        stderr=stderr,
    )

    assert unknown_status == 1
    assert missing_status == 1
    assert "Could not determine the frontmost macOS app" in stderr.getvalue()
    assert "XQuartz is frontmost, but no active X11 window was found" in stderr.getvalue()


@pytest.mark.parametrize(
    ("function", "arguments", "usage"),
    [
        (move, [], "aerospace-x11-aware-move"),
        (move, ["diagonal"], "aerospace-x11-aware-move"),
        (resize, ["50"], "aerospace-x11-aware-resize"),
        (resize, ["+wide"], "aerospace-x11-aware-resize"),
    ],
)
def test_rejects_invalid_actions(
    function: Callable[..., int],
    arguments: list[str],
    usage: str,
) -> None:
    stderr = io.StringIO()

    status = function(
        arguments,
        environment={},
        frontmost=FixedFrontmostApplication("com.apple.Terminal"),
        x11=RecordingX11Windows(),
        aerospace=RecordingAerospace(),
        stderr=stderr,
    )

    assert status == 64
    assert usage in stderr.getvalue()
