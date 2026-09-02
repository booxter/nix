from __future__ import annotations

from enum import StrEnum
from pathlib import Path
from typing import Literal
from uuid import UUID

from atomic_file_writes import write_text_atomic
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .errors import PostProcessorError
from .radarr_repair import RepairTask


class JobStatus(StrEnum):
    SETTLING = "settling"
    AGENT_STARTING = "agent_starting"
    AGENT_RUNNING = "agent_running"
    AGENT_STOPPING = "agent_stopping"
    READY = "ready"
    IMPORTING = "importing"
    AWAITING_QUEUE_REMOVAL = "awaiting_queue_removal"
    NEEDS_ATTENTION = "needs_attention"
    COMPLETE = "complete"
    MANUAL_RESOLVED = "manual_resolved"


ACTIVE_AGENT_STATES = {
    JobStatus.AGENT_STARTING,
    JobStatus.AGENT_RUNNING,
    JobStatus.AGENT_STOPPING,
}


class FailureKind(StrEnum):
    AGENT_UNRESOLVED = "agent_unresolved"
    AGENT_FAILED = "agent_failed"
    AGENT_CANCELLED = "agent_cancelled"
    AGENT_TIMED_OUT = "agent_timed_out"
    AGENT_LOST = "agent_lost"
    AGENT_START_AMBIGUOUS = "agent_start_ambiguous"
    APPROVAL_REQUIRED = "approval_required"
    INVALID_OUTPUT = "invalid_output"
    SOURCE_CHANGED = "source_changed"
    SOURCE_INVALID = "source_invalid"
    IMPORT_REJECTED = "import_rejected"
    IMPORT_FAILED = "import_failed"


class RepairTotals(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)

    success: int = 0
    agent_unresolved: int = 0
    agent_failed: int = 0
    agent_cancelled: int = 0
    agent_timed_out: int = 0
    agent_lost: int = 0
    agent_start_ambiguous: int = 0
    approval_required: int = 0
    invalid_output: int = 0
    source_changed: int = 0
    source_invalid: int = 0
    import_rejected: int = 0
    import_failed: int = 0
    manual: int = 0

    def increment_failure(self, kind: FailureKind) -> None:
        field = kind.value
        setattr(self, field, getattr(self, field) + 1)


class RepairJob(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)

    download_id: str = Field(min_length=1)
    title: str = ""
    status: JobStatus = JobStatus.SETTLING
    source_fingerprint: str = ""
    discovered_at: float
    updated_at: float
    attempt_id: UUID | None = None
    run_id: str | None = None
    task: RepairTask | None = None
    task_root: Path | None = None
    candidate: Path | None = None
    started_at: float | None = None
    agent_deadline_at: float | None = None
    stop_deadline_at: float | None = None
    pending_failure_kind: FailureKind | None = None
    dismiss_requested: bool = False
    command_id: int | None = None
    import_deadline_at: float | None = None
    failure_kind: FailureKind | None = None
    error: str = ""
    resolution: str = ""
    missing_queue_observations: int = 0


class RetainedArtifact(BaseModel):
    model_config = ConfigDict(extra="forbid")

    download_id: str
    attempt_id: UUID
    path: Path
    expires_at: float


class RepairState(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)

    schema_version: Literal[1] = 1
    jobs: dict[str, RepairJob] = Field(default_factory=dict)
    retained_artifacts: list[RetainedArtifact] = Field(default_factory=list)
    totals: RepairTotals = Field(default_factory=RepairTotals)
    last_success: float | None = None
    last_duration: float = 0.0


class RepairStateStore:
    def __init__(self, path: Path):
        self.path = path
        self.state = RepairState()
        self.load()

    def load(self) -> None:
        try:
            self.state = RepairState.model_validate_json(self.path.read_bytes())
        except FileNotFoundError:
            return
        except (OSError, ValidationError) as error:
            raise PostProcessorError(
                f"cannot load Radarr repair state {self.path}: {error}"
            ) from error

    def save(self) -> None:
        write_text_atomic(self.path, f"{self.state.model_dump_json(indent=2)}\n", mode=0o640)

    def prune_jobs(self, now: float, retention_seconds: float = 7 * 86400) -> None:
        expiring = {JobStatus.COMPLETE, JobStatus.MANUAL_RESOLVED}
        self.state.jobs = {
            key: job
            for key, job in self.state.jobs.items()
            if job.status not in expiring or now - job.updated_at < retention_seconds
        }
