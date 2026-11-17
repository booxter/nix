from __future__ import annotations

import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from sketchybar_applet.errors import SketchybarError


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
            raise SketchybarError(f"Cannot run SketchyBar: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip()
            message = f"SketchyBar exited with status {result.returncode}"
            if detail:
                message += f": {detail}"
            raise SketchybarError(message)


def sketchybar_executable(environment: Mapping[str, str]) -> str:
    executable = environment.get("SKETCHYBAR_BIN", "")
    if not executable:
        raise SketchybarError("missing environment setting SKETCHYBAR_BIN")
    return executable
