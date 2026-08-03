import os
import re
import sys
from collections.abc import Mapping, Sequence
from typing import TextIO

from aerospace_x11.native import AerospaceCli, CocoaFrontmostApplication, XlibWindows
from aerospace_x11.service import (
    ActionError,
    Aerospace,
    Direction,
    FrontmostApplication,
    WindowActions,
    X11Windows,
    display_names,
)


def _dependencies(
    frontmost: FrontmostApplication | None,
    x11: X11Windows | None,
    aerospace: Aerospace | None,
) -> WindowActions:
    return WindowActions(
        frontmost or CocoaFrontmostApplication(),
        x11 or XlibWindows(),
        aerospace or AerospaceCli(),
    )


def move(
    argv: Sequence[str],
    *,
    environment: Mapping[str, str],
    frontmost: FrontmostApplication | None = None,
    x11: X11Windows | None = None,
    aerospace: Aerospace | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    if len(argv) != 1 or argv[0] not in {direction.value for direction in Direction}:
        print("Usage: aerospace-x11-aware-move left|down|up|right", file=stderr)
        return 64
    try:
        return _dependencies(frontmost, x11, aerospace).move(
            Direction(argv[0]),
            display_names(environment),
        )
    except ActionError as error:
        print(error, file=stderr)
        return 1


def resize(
    argv: Sequence[str],
    *,
    environment: Mapping[str, str],
    frontmost: FrontmostApplication | None = None,
    x11: X11Windows | None = None,
    aerospace: Aerospace | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    if len(argv) != 1 or re.fullmatch(r"[+-]\d+", argv[0]) is None:
        print("Usage: aerospace-x11-aware-resize +/-pixels", file=stderr)
        return 64
    try:
        return _dependencies(frontmost, x11, aerospace).resize(
            int(argv[0]),
            display_names(environment),
        )
    except ActionError as error:
        print(error, file=stderr)
        return 1


def move_main() -> int:
    return move(sys.argv[1:], environment=os.environ)


def resize_main() -> int:
    return resize(sys.argv[1:], environment=os.environ)
