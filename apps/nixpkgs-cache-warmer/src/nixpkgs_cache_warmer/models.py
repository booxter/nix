from pathlib import Path

from pydantic import BaseModel, ConfigDict


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
