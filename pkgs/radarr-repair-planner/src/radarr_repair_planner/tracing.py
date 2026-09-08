from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Protocol, TextIO

MetadataValue = str | int | float | bool | None


@dataclass(frozen=True)
class ModelTrace:
    case_id: str
    raw_output: str | None
    reasoning: str | None
    response_metadata: dict[str, MetadataValue]
    error: str | None


class TraceSink(Protocol):
    def record(self, trace: ModelTrace) -> None: ...


@dataclass
class JsonlTraceWriter:
    path: Path
    case_names: dict[str, str]
    _attempts: dict[str, int] = field(default_factory=dict, init=False)
    _file: TextIO = field(init=False, repr=False)

    def __post_init__(self) -> None:
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(self.path, flags, 0o600)
        os.fchmod(descriptor, 0o600)
        self._file = os.fdopen(descriptor, "w", encoding="utf-8")

    def record(self, trace: ModelTrace) -> None:
        attempt = self._attempts.get(trace.case_id, 0) + 1
        self._attempts[trace.case_id] = attempt
        value = {
            "case_name": self.case_names.get(trace.case_id),
            "attempt": attempt,
            **asdict(trace),
        }
        self._file.write(json.dumps(value, allow_nan=False) + "\n")
        self._file.flush()

    def close(self) -> None:
        self._file.close()

    def __enter__(self) -> JsonlTraceWriter:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()
