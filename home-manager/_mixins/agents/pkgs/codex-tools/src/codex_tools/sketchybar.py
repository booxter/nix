from __future__ import annotations

import datetime as dt
import math
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from codex_tools.errors import CodexToolsError

DEFAULT_BLUE = "0xff83a598"
DEFAULT_GREEN = "0xffb8bb26"
DEFAULT_NEUTRAL = "0xffd5c4a1"
DEFAULT_RED = "0xfffb4934"


@dataclass(frozen=True)
class Colors:
    green: str
    red: str
    blue: str
    neutral: str

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> Colors:
        return cls(
            green=environment.get("SKETCHYBAR_COLOR_GREEN", DEFAULT_GREEN),
            red=environment.get("SKETCHYBAR_COLOR_RED", DEFAULT_RED),
            blue=environment.get("SKETCHYBAR_COLOR_BLUE", DEFAULT_BLUE),
            neutral=environment.get("SKETCHYBAR_COLOR_NEUTRAL", DEFAULT_NEUTRAL),
        )


class Sketchybar(Protocol):
    def run(self, arguments: Sequence[str]) -> None: ...


@dataclass(frozen=True)
class SketchybarCommand:
    executable: str

    def run(self, arguments: Sequence[str]) -> None:
        try:
            result = subprocess.run(
                [self.executable, *arguments],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise CodexToolsError(f"Cannot run SketchyBar: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip()
            message = f"SketchyBar exited with status {result.returncode}"
            if detail:
                message += f": {detail}"
            raise CodexToolsError(message)


def sketchybar_executable(environment: Mapping[str, str]) -> str:
    executable = environment.get("SKETCHYBAR_BIN", "")
    if not executable:
        raise CodexToolsError("missing environment setting SKETCHYBAR_BIN")
    return executable


def format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "?"
    if seconds < 0:
        return "expired"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3_600:
        return f"{seconds // 60}m"
    if seconds < 86_400:
        return f"{seconds // 3_600}h{seconds % 3_600 // 60:02d}"
    return f"{seconds // 86_400}d{seconds % 86_400 // 3_600:02d}h"


def format_epoch_local(epoch: int | float | None) -> str | None:
    if epoch is None:
        return None
    try:
        value = dt.datetime.fromtimestamp(epoch).astimezone()
    except (OSError, OverflowError, ValueError):
        return None
    return value.strftime("%Y-%m-%d %H:%M %Z")


def _mix_channel(start: int, end: int, numerator: int, denominator: int) -> int:
    return (start * (denominator - numerator) + end * numerator + denominator // 2) // denominator


def gradient_color(risk_bps: int | None, colors: Colors) -> str:
    if risk_bps is None:
        return colors.blue
    if risk_bps <= 1_000:
        return colors.green
    if risk_bps <= 1_100:
        start, end = 1_000, 1_100
        source, target = (0x9E, 0xCE, 0x6A), (0xE0, 0xAF, 0x68)
    elif risk_bps <= 1_250:
        start, end = 1_100, 1_250
        source, target = (0xE0, 0xAF, 0x68), (0xFF, 0x9E, 0x64)
    elif risk_bps <= 1_500:
        start, end = 1_250, 1_500
        source, target = (0xFF, 0x9E, 0x64), (0xF7, 0x76, 0x8E)
    else:
        return colors.red
    numerator = risk_bps - start
    denominator = end - start
    red, green, blue = (
        _mix_channel(source[index], target[index], numerator, denominator) for index in range(3)
    )
    return f"0xff{red:02x}{green:02x}{blue:02x}"


def pace_color(risk_bps: int | None, *, reached: bool, colors: Colors) -> str:
    return colors.red if reached else gradient_color(risk_bps, colors)


def rounded_risk_bps(used_percent: int | float, window: int, elapsed: int) -> int | None:
    if used_percent <= 0:
        return 0
    if window <= 0 or elapsed <= 0:
        return None
    return math.floor(used_percent * window * 10 / elapsed + 0.5)
