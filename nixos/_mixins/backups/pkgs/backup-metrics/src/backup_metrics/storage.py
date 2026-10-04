from __future__ import annotations

import fcntl
from collections.abc import Iterator, Mapping
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic

from .metrics import backup_registry, write_registry
from .models import BackupState, JobsConfig
from .state import read_state, write_state


class MetricsStore(Protocol):
    def transaction(self) -> AbstractContextManager[None]: ...

    def configuration(self) -> JobsConfig: ...

    def configure(self, configuration: JobsConfig) -> None: ...

    def read(self, job_name: str) -> BackupState | None: ...

    def write(self, job_name: str, state: BackupState) -> None: ...

    def publish(self, configuration: JobsConfig, states: Mapping[str, BackupState]) -> None: ...


@dataclass(frozen=True)
class FileMetricsStore:
    state_directory: Path
    metrics_path: Path

    @contextmanager
    def transaction(self) -> Iterator[None]:
        self.state_directory.mkdir(parents=True, exist_ok=True)
        with (self.state_directory / ".publication.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    @property
    def configuration_path(self) -> Path:
        return self.state_directory / ".configured-jobs.json"

    def state_path(self, job_name: str) -> Path:
        filename = job_name.translate(str.maketrans("/. ", "---"))
        return self.state_directory / f"{filename}.json"

    def configuration(self) -> JobsConfig:
        return JobsConfig.model_validate_json(self.configuration_path.read_text(encoding="utf-8"))

    def configure(self, configuration: JobsConfig) -> None:
        write_text_atomic(self.configuration_path, configuration.model_dump_json(), mode=0o644)

    def read(self, job_name: str) -> BackupState | None:
        return read_state(self.state_path(job_name))

    def write(self, job_name: str, state: BackupState) -> None:
        write_state(self.state_path(job_name), state)

    def publish(self, configuration: JobsConfig, states: Mapping[str, BackupState]) -> None:
        write_registry(self.metrics_path, backup_registry(configuration, states))
