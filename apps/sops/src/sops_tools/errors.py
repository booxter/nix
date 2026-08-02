from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence


class ToolError(RuntimeError):
    """An expected error that should be shown without a traceback."""


@dataclass(frozen=True)
class CommandError(ToolError):
    argv: Sequence[str]
    returncode: int
    stderr: str

    def __str__(self) -> str:
        detail = self.stderr.strip()
        if detail:
            return detail
        return f"Command failed with exit code {self.returncode}: {' '.join(self.argv)}"
