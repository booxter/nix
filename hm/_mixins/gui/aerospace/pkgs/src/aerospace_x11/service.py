from collections.abc import Mapping, Sequence
from enum import StrEnum
from pathlib import Path
from typing import Protocol


XQUARTZ_BUNDLE_IDENTIFIERS = frozenset(("org.nixos.xquartz.X11", "org.x.X11"))


class ActionError(Exception):
    """A window action could not be routed safely."""


class Direction(StrEnum):
    LEFT = "left"
    DOWN = "down"
    UP = "up"
    RIGHT = "right"


class FrontmostApplication(Protocol):
    def bundle_identifier(self) -> str | None: ...


class X11Windows(Protocol):
    def move_active(self, display: str, direction: Direction) -> bool: ...

    def resize_active(self, display: str, delta: int) -> bool: ...


class Aerospace(Protocol):
    def move(self, direction: Direction) -> int: ...

    def resize(self, delta: int) -> int: ...


def display_names(
    environment: Mapping[str, str],
    socket_directories: Sequence[Path] = (
        Path("/tmp/.X11-unix"),
        Path("/private/tmp/.X11-unix"),
    ),
) -> tuple[str, ...]:
    displays: list[str] = []

    def add(display: str | None) -> None:
        if display and display not in displays:
            displays.append(display)

    add(environment.get("XQUARTZ_DISPLAY"))
    add(environment.get("DISPLAY"))
    for directory in socket_directories:
        try:
            sockets = sorted(directory.glob("X*"))
        except OSError:
            continue
        for socket in sockets:
            number = socket.name.removeprefix("X")
            if number:
                add(f":{number}")
    for display_number in range(10):
        add(f":{display_number}")
    return tuple(displays)


def moved_position(x: int, y: int, direction: Direction, step: int = 50) -> tuple[int, int]:
    if direction is Direction.LEFT:
        x -= step
    elif direction is Direction.RIGHT:
        x += step
    elif direction is Direction.UP:
        y -= step
    else:
        y += step
    return max(0, x), max(0, y)


def resized_dimensions(width: int, height: int, delta: int) -> tuple[int, int]:
    return max(50, width + delta), max(50, height + delta)


class WindowActions:
    def __init__(
        self,
        frontmost: FrontmostApplication,
        x11: X11Windows,
        aerospace: Aerospace,
    ) -> None:
        self.frontmost = frontmost
        self.x11 = x11
        self.aerospace = aerospace

    def _frontmost_bundle_identifier(self, action: str) -> str:
        bundle_identifier = self.frontmost.bundle_identifier()
        if bundle_identifier is None:
            raise ActionError(
                "Could not determine the frontmost macOS app; refusing to "
                f"{action} a background AeroSpace window."
            )
        return bundle_identifier

    def move(self, direction: Direction, displays: Sequence[str]) -> int:
        if self._frontmost_bundle_identifier("move") not in XQUARTZ_BUNDLE_IDENTIFIERS:
            return self.aerospace.move(direction)
        if any(self.x11.move_active(display, direction) for display in displays):
            return 0
        raise ActionError("XQuartz is frontmost, but no active X11 window was found.")

    def resize(self, delta: int, displays: Sequence[str]) -> int:
        if self._frontmost_bundle_identifier("resize") not in XQUARTZ_BUNDLE_IDENTIFIERS:
            return self.aerospace.resize(delta)
        if any(self.x11.resize_active(display, delta) for display in displays):
            return 0
        raise ActionError("XQuartz is frontmost, but no active X11 window was found.")
