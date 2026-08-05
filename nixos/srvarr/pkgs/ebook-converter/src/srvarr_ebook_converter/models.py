from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class MutableModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        strict=True,
        validate_assignment=True,
    )


class FileFingerprint(MutableModel):
    device: int
    inode: int
    size: int = Field(ge=0)
    mtime_ns: int


class JobState(MutableModel):
    status: str
    fingerprint: FileFingerprint
    policy_version: int | None = None
    observed_at: float
    updated_at: float
    attempts: int = Field(default=0, ge=0)
    error: str = ""
    destination: str | None = None


class ConversionTotals(MutableModel):
    success: int = Field(default=0, ge=0)
    failed: int = Field(default=0, ge=0)


class ServiceState(MutableModel):
    version: Literal[1] = 1
    files: dict[str, JobState] = Field(default_factory=dict)
    totals: ConversionTotals = Field(default_factory=ConversionTotals)
    last_success: float | None = None


class ShelfmarkOutput(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True)

    mode: str


class ShelfmarkPaths(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True)

    final_paths: list[str]


class ShelfmarkPayload(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True)

    version: Literal[1]
    phase: str
    output: ShelfmarkOutput | None = None
    paths: ShelfmarkPaths | None = None
