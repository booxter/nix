from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from sketchybar_applet import Colors, sketchybar_executable


@dataclass(frozen=True)
class Config:
    auth_file: Path
    colors: Colors
    sketchybar_executable: str

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> Config:
        home = Path(environment.get("HOME", str(Path.home())))
        return cls(
            auth_file=home / ".codex" / "auth.json",
            colors=Colors.from_environment(environment),
            sketchybar_executable=sketchybar_executable(environment),
        )
