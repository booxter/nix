from datetime import datetime
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, model_validator

PackageSelector = tuple[str, ...]


class PackageTarget(BaseModel):
    """A buildable maintained package selected from nixpkgs."""

    model_config = ConfigDict(frozen=True)

    drvPath: Path
    name: str
    pname: str
    outputs: tuple[Path, ...]


class LockedFlakeReference(BaseModel):
    model_config = ConfigDict(frozen=True)

    rev: str | None = None


class FlakeMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    locked: LockedFlakeReference
    path: Path


class ResolvedSource(BaseModel):
    """An immutable nixpkgs source and its Git revision."""

    model_config = ConfigDict(frozen=True)

    reference: str
    revision: str
    source: Path


class RunRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    attempted_at: datetime
    revision: str | None
    status: Literal["success", "partial", "failed"]
    selected: int
    built: int
    failed: int
    error: str | None = None

    @model_validator(mode="before")
    @classmethod
    def discard_legacy_pushed_count(cls, value: object) -> object:
        if isinstance(value, dict) and "pushed" in value:
            migrated = dict(value)
            del migrated["pushed"]
            return migrated
        return value


class TargetState(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    reference: str
    system: str
    last_attempt: RunRecord
    last_success: RunRecord | None = None


class WarmerState(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal[1] = 1
    targets: tuple[TargetState, ...] = ()
