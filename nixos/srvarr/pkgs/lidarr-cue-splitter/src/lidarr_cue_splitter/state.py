from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from pydantic import TypeAdapter, ValidationError

from .errors import CueSplitterError
from .files import atomic_write


EXPIRING_JOB_STATES = {
    "complete",
    "dismissed",
    "ignored",
    "manual_resolved",
    "source_invalid",
    "source_unavailable",
}


@dataclass
class Job:
    download_id: str = ""
    title: str = ""
    status: str = "unknown"
    fingerprint: str = ""
    discovered_at: float | None = None
    updated_at: float | None = None
    attempts: int = 0
    ready_root: Path | None = None
    tracks: int = 0
    command_id: int | None = None
    started_at: float | None = None
    error: str = ""
    failure_fingerprint: str | None = None
    failure_kind: str | None = None
    resolution: str | None = None
    missing_queue_observations: int = 0


@dataclass
class Totals:
    success: int = 0
    failed: int = 0
    ignored: int = 0
    manual: int = 0
    source_invalid: int = 0
    source_unavailable: int = 0
    tracks: int = 0


@dataclass
class State:
    jobs: dict[str, Job] = field(default_factory=dict)
    totals: Totals = field(default_factory=Totals)
    last_success: float | None = None
    last_duration: float = 0.0


STATE_ADAPTER = TypeAdapter(State)


class StateStore:
    def __init__(self, path: Path):
        self.path = path
        self.state = State()
        self.load()

    def load(self) -> None:
        try:
            self.state = STATE_ADAPTER.validate_json(self.path.read_bytes())
        except FileNotFoundError:
            return
        except (OSError, ValidationError) as error:
            raise CueSplitterError(f"cannot load state {self.path}: {error}") from error

    def save(self) -> None:
        content = STATE_ADAPTER.dump_json(self.state, indent=2).decode()
        atomic_write(self.path, f"{content}\n")

    def job(self, download_id: str, *, title: str = "") -> Job:
        return self.state.jobs.setdefault(
            download_id,
            Job(download_id=download_id, title=title),
        )

    def prune(self, now: float, retention_seconds: float = 7 * 86400) -> None:
        self.state.jobs = {
            key: job
            for key, job in self.state.jobs.items()
            if job.status not in EXPIRING_JOB_STATES
            or now - (job.updated_at if job.updated_at is not None else now) < retention_seconds
        }
