from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field

NonEmpty = Annotated[str, Field(min_length=1)]


class BackupJob(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    backup_job: NonEmpty
    backup_title: NonEmpty
    phase: NonEmpty
    unit: NonEmpty


class JobsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    jobs: tuple[BackupJob, ...]


class BackupState(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    last_run_timestamp_seconds: float
    last_success_timestamp_seconds: float
    last_duration_seconds: float
    last_success: bool
    service_result: str
    exit_code: str
    exit_status: str


@dataclass(frozen=True)
class Outcome:
    service_result: str
    exit_code: str
    exit_status: str

    @property
    def succeeded(self) -> bool:
        return self.service_result == "success"
