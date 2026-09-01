from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path, PurePosixPath
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

from .errors import NeedsAttention

RESULT_FILE_NAME = "result.json"
REPORT_FILE_NAME = "report.md"
VIDEO_SUFFIXES = frozenset(
    {".avi", ".m2ts", ".m4v", ".mkv", ".mov", ".mp4", ".mpeg", ".mpg", ".ts", ".webm", ".wmv"}
)


class RepairOutcome(StrEnum):
    REPAIRED = "repaired"
    UNRESOLVED = "unresolved"


class RepairTask(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1] = 1
    attempt_id: UUID
    download_id: str = Field(min_length=1)
    source_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    movie_id: int = Field(gt=0)
    movie_title: str = Field(min_length=1)
    movie_year: int = Field(ge=1800)
    movie_runtime_minutes: int = Field(ge=0)
    queue_title: str = Field(min_length=1)
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


class RepairResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1]
    attempt_id: UUID
    download_id: str = Field(min_length=1)
    source_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    outcome: RepairOutcome
    candidate: str | None
    reason: str = Field(min_length=1)

    @field_validator("candidate")
    @classmethod
    def validate_candidate_path(cls, value: str | None) -> str | None:
        if value is None:
            return None
        path = PurePosixPath(value)
        if path.is_absolute() or path == PurePosixPath(".") or ".." in path.parts or "\\" in value:
            raise ValueError("candidate must be a normalized relative POSIX path")
        return value

    @model_validator(mode="after")
    def validate_outcome(self) -> RepairResult:
        if self.outcome is RepairOutcome.REPAIRED and self.candidate is None:
            raise ValueError("repaired results require a candidate")
        if self.outcome is RepairOutcome.UNRESOLVED and self.candidate is not None:
            raise ValueError("unresolved results cannot declare a candidate")
        return self


@dataclass(frozen=True)
class ValidatedRepairResult:
    result: RepairResult
    candidate: Path | None


def render_repair_instruction(task: RepairTask) -> str:
    return f"""Repair the Radarr download described by the task below.

Follow MEDIA_WORKFLOW.md. Work autonomously: do not request approval. Inspect only the declared
source and write only beneath the declared output directory. Do not rename, modify, or delete the
source. If a safe repair is possible, place the final media candidate beneath the output directory.
Always write report.md, then write result.json last using schema version 1. The candidate in
result.json must be relative to the output directory. If no safe repair is justified, report the
outcome as unresolved and do not guess.

Task:
{task.model_dump_json(indent=2)}
"""


def _reject_symlinks(root: Path, relative: PurePosixPath) -> None:
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise NeedsAttention(f"repair candidate traverses a symlink: {relative}")


def load_repair_result(task_root: Path, expected: RepairTask) -> ValidatedRepairResult:
    try:
        root = task_root.resolve(strict=True)
    except OSError as error:
        raise NeedsAttention(f"repair task directory is unavailable: {error}") from error
    result_path = root / RESULT_FILE_NAME
    if result_path.is_symlink():
        raise NeedsAttention("repair result manifest is a symlink")
    try:
        result = RepairResult.model_validate_json(result_path.read_bytes())
    except FileNotFoundError as error:
        raise NeedsAttention("repair result manifest is missing") from error
    except (OSError, ValidationError) as error:
        raise NeedsAttention(f"repair result manifest is invalid: {error}") from error

    if (
        result.attempt_id != expected.attempt_id
        or result.download_id != expected.download_id
        or result.source_fingerprint != expected.source_fingerprint
    ):
        raise NeedsAttention("repair result does not match its requested attempt")
    report_path = root / REPORT_FILE_NAME
    if report_path.is_symlink() or not report_path.is_file():
        raise NeedsAttention("repair report is missing or is not a regular file")
    try:
        report_mode = report_path.stat().st_mode
    except OSError as error:
        raise NeedsAttention(f"cannot inspect repair report: {error}") from error
    if not report_mode & 0o040:
        raise NeedsAttention("repair report is not group-readable")
    if result.outcome is RepairOutcome.UNRESOLVED:
        return ValidatedRepairResult(result=result, candidate=None)

    assert result.candidate is not None
    relative = PurePosixPath(result.candidate)
    _reject_symlinks(root, relative)
    try:
        candidate = (root / Path(*relative.parts)).resolve(strict=True)
    except OSError as error:
        raise NeedsAttention(f"repair candidate is unavailable: {error}") from error
    if not candidate.is_relative_to(root):
        raise NeedsAttention("repair candidate escapes its task directory")
    if not candidate.is_file():
        raise NeedsAttention("repair candidate is not a regular file")
    if candidate.suffix.lower() not in VIDEO_SUFFIXES:
        raise NeedsAttention(f"repair candidate has an unsupported suffix: {candidate.suffix}")
    try:
        mode = candidate.stat().st_mode
    except OSError as error:
        raise NeedsAttention(f"cannot inspect repair candidate: {error}") from error
    if not mode & 0o040:
        raise NeedsAttention("repair candidate is not group-readable")
    return ValidatedRepairResult(result=result, candidate=candidate)
