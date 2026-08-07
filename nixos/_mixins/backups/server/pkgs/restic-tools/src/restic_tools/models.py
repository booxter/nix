from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        populate_by_name=True,
        strict=True,
    )


class RepositoryConfig(StrictModel):
    name: str
    backup_job: str = Field(alias="backupJob")
    backup_title: str = Field(alias="backupTitle")
    bucket: str
    prefix: str
    repository: str
    password_file: Path = Field(alias="passwordFile")


class ExporterConfig(StrictModel):
    buckets: tuple[str, ...]
    b2_application_key_id_file: Path = Field(alias="b2ApplicationKeyIdFile")
    b2_application_key_file: Path = Field(alias="b2ApplicationKeyFile")
    repositories: tuple[RepositoryConfig, ...]


class OffloadConfig(StrictModel):
    source_repository: Path = Field(alias="sourceRepository")
    source_password_file: Path = Field(alias="sourcePasswordFile")
    destination_repository: str = Field(alias="destinationRepository", min_length=1)
    destination_password_file: Path = Field(alias="destinationPasswordFile")
    b2_application_key_id_file: Path | None = Field(default=None, alias="b2ApplicationKeyIdFile")
    b2_application_key_file: Path | None = Field(default=None, alias="b2ApplicationKeyFile")
    b2_connections: int = Field(default=1, alias="b2Connections", gt=0)
    pack_size_mib: int = Field(alias="packSizeMib", gt=0)
    prune_options: tuple[str, ...] = Field(alias="pruneOptions")


class AttemptState(StrictModel):
    last_run_timestamp_seconds: float = 0
    last_success_timestamp_seconds: float = 0
    last_duration_seconds: float = 0
    last_success: Literal[0, 1] = 0
    exit_code: int = 0


class BucketState(AttemptState):
    total_size_bytes: int = Field(default=0, ge=0)
    file_count: int = Field(default=0, ge=0)


class RepositoryState(AttemptState):
    total_size_bytes: int = Field(default=0, ge=0)
    total_uncompressed_size_bytes: int = Field(default=0, ge=0)
    total_blob_count: int = Field(default=0, ge=0)
    snapshots_count: int = Field(default=0, ge=0)


class ExporterState(StrictModel):
    buckets: dict[str, BucketState] = Field(default_factory=dict)
    repositories: dict[str, RepositoryState] = Field(default_factory=dict)


class BucketUsage(StrictModel):
    total_size_bytes: int = Field(ge=0)
    file_count: int = Field(ge=0)


class ResticStats(StrictModel):
    total_size: int = Field(ge=0)
    total_uncompressed_size: int = Field(ge=0)
    total_blob_count: int = Field(ge=0)
    snapshots_count: int = Field(ge=0)
