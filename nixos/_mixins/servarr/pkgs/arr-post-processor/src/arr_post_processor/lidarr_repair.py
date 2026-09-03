from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path, PurePosixPath
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

from .errors import NeedsAttention
from .models import AlbumCatalog, StatusMessage
from .repair_media import AUDIO_FILE_SUFFIXES

RESULT_FILE_NAME = "result.json"
REPORT_FILE_NAME = "report.md"


class RepairOutcome(StrEnum):
    REPAIRED = "repaired"
    UNRESOLVED = "unresolved"


class LidarrQueueStatus(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: str = ""
    tracked_download_status: str = ""
    tracked_download_state: str = ""
    messages: list[StatusMessage] = Field(default_factory=list)


class RepairTask(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1] = 1
    attempt_id: UUID
    download_id: str = Field(min_length=1)
    source_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    queue_title: str = Field(min_length=1)
    lidarr_queue_status: LidarrQueueStatus = Field(default_factory=LidarrQueueStatus)
    catalog: AlbumCatalog
    source_path: str = Field(min_length=1)
    output_path: str = Field(min_length=1)

    @field_validator("source_path", "output_path")
    @classmethod
    def validate_workspace_path(cls, value: str) -> str:
        path = PurePosixPath(value)
        if (
            path.is_absolute()
            or path == PurePosixPath(".")
            or ".." in path.parts
            or value.startswith("./")
        ):
            raise ValueError("workspace paths must be normalized relative paths")
        return value


class RepairFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    candidate: str = Field(min_length=1)
    expected_track_ids: list[int] = Field(min_length=1)

    @field_validator("candidate")
    @classmethod
    def validate_candidate_path(cls, value: str) -> str:
        path = PurePosixPath(value)
        if path.is_absolute() or path == PurePosixPath(".") or ".." in path.parts or "\\" in value:
            raise ValueError("candidate must be a normalized relative POSIX path")
        return value

    @field_validator("expected_track_ids")
    @classmethod
    def validate_track_ids(cls, value: list[int]) -> list[int]:
        if any(track_id <= 0 for track_id in value) or len(value) != len(set(value)):
            raise ValueError("expected track IDs must be positive and unique")
        return value


class RepairResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1]
    attempt_id: UUID
    download_id: str = Field(min_length=1)
    source_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    outcome: RepairOutcome
    release_id: int | None
    files: list[RepairFile]
    reason: str = Field(min_length=1)

    @model_validator(mode="after")
    def validate_outcome(self) -> RepairResult:
        if self.outcome is RepairOutcome.REPAIRED and (self.release_id is None or not self.files):
            raise ValueError("repaired results require a release and files")
        if self.outcome is RepairOutcome.UNRESOLVED and (self.release_id is not None or self.files):
            raise ValueError("unresolved results cannot declare a release or files")
        candidates = [item.candidate for item in self.files]
        if len(candidates) != len(set(candidates)):
            raise ValueError("repair candidates must be unique")
        track_ids = [track_id for item in self.files for track_id in item.expected_track_ids]
        if len(track_ids) != len(set(track_ids)):
            raise ValueError("expected tracks must occur exactly once")
        return self


@dataclass(frozen=True)
class ValidatedRepairFile:
    path: Path
    expected_track_ids: tuple[int, ...]


@dataclass(frozen=True)
class ValidatedRepairResult:
    result: RepairResult
    files: tuple[ValidatedRepairFile, ...]


def render_repair_instruction(task: RepairTask) -> str:
    return f"""Repair the Lidarr download described by the task below.

Follow MEDIA_WORKFLOW.md. Work autonomously: do not request approval. Inspect only the declared
source and write only beneath the declared output directory. Do not rename, modify, or delete the
source. Produce media only when it can satisfy exactly one catalog release. Always write report.md,
then write result.json last using schema version 1. Candidate paths in result.json must be relative
to the output directory. If no safe and complete repair is justified, report the outcome as
unresolved and do not guess.

Task:
{task.model_dump_json(indent=2)}
"""


def _resolve_task_root(task_root: Path) -> Path:
    try:
        return task_root.resolve(strict=True)
    except OSError as error:
        raise NeedsAttention(f"repair task directory is unavailable: {error}") from error


def _reject_symlinks(root: Path, relative: PurePosixPath) -> None:
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise NeedsAttention(f"repair candidate traverses a symlink: {relative}")


def _load_result(root: Path) -> RepairResult:
    path = root / RESULT_FILE_NAME
    if path.is_symlink():
        raise NeedsAttention("repair result manifest is a symlink")
    try:
        return RepairResult.model_validate_json(path.read_bytes())
    except FileNotFoundError as error:
        raise NeedsAttention("repair result manifest is missing") from error
    except (OSError, ValidationError) as error:
        raise NeedsAttention(f"repair result manifest is invalid: {error}") from error


def _validate_identity(result: RepairResult, expected: RepairTask) -> None:
    if (
        result.attempt_id != expected.attempt_id
        or result.download_id != expected.download_id
        or result.source_fingerprint != expected.source_fingerprint
    ):
        raise NeedsAttention("repair result does not match its requested attempt")


def _validate_report(root: Path) -> None:
    path = root / REPORT_FILE_NAME
    if path.is_symlink() or not path.is_file():
        raise NeedsAttention("repair report is missing or is not a regular file")
    if not path.stat().st_mode & 0o040:
        raise NeedsAttention("repair report is not group-readable")


def _validate_catalog(result: RepairResult, task: RepairTask) -> None:
    if result.outcome is RepairOutcome.UNRESOLVED:
        return
    assert result.release_id is not None
    releases = {item.release.id: item for item in task.catalog.releases}
    release = releases.get(result.release_id)
    if release is None:
        raise NeedsAttention("repair result selected a release outside the task catalog")
    expected = {track.id for track in release.tracks}
    actual = {track_id for item in result.files for track_id in item.expected_track_ids}
    if actual != expected:
        raise NeedsAttention("repair result does not cover exactly the selected release")


def _validate_file(root: Path, item: RepairFile) -> ValidatedRepairFile:
    relative = PurePosixPath(item.candidate)
    _reject_symlinks(root, relative)
    try:
        path = (root / Path(*relative.parts)).resolve(strict=True)
    except OSError as error:
        raise NeedsAttention(f"repair candidate is unavailable: {error}") from error
    if not path.is_relative_to(root) or not path.is_file():
        raise NeedsAttention("repair candidate escapes its task directory or is not a file")
    if path.suffix.lower() not in AUDIO_FILE_SUFFIXES:
        raise NeedsAttention(f"repair candidate has an unsupported suffix: {path.suffix}")
    if not path.stat().st_mode & 0o040:
        raise NeedsAttention("repair candidate is not group-readable")
    return ValidatedRepairFile(path=path, expected_track_ids=tuple(item.expected_track_ids))


def load_repair_result(task_root: Path, expected: RepairTask) -> ValidatedRepairResult:
    root = _resolve_task_root(task_root)
    result = _load_result(root)
    _validate_identity(result, expected)
    _validate_report(root)
    _validate_catalog(result, expected)
    files = tuple(_validate_file(root, item) for item in result.files)
    return ValidatedRepairResult(result=result, files=files)
