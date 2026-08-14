from __future__ import annotations

from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter


class ArtifactBase(BaseModel):
    model_config = ConfigDict(extra="forbid")

    destination_dir: Path = Field(alias="destinationDir")


class PostgreSQLArtifact(ArtifactBase):
    kind: Literal["postgresql"]
    database: str = Field(pattern=r"^[A-Za-z0-9_.-]+$")
    executable: Path


class MariaDBArtifact(ArtifactBase):
    kind: Literal["mariadb"]
    database: str = Field(pattern=r"^[A-Za-z0-9_.-]+$")
    executable: Path


class ExtraCopy(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source: Path
    mode: str = Field(pattern=r"^0[0-7]{3}$")
    optional: bool

    @property
    def numeric_mode(self) -> int:
        return int(self.mode, 8)


class SQLiteArtifact(ArtifactBase):
    kind: Literal["sqlite"]
    database_path: Path = Field(alias="databasePath")
    extra_copies: tuple[ExtraCopy, ...] = Field(default=(), alias="extraCopies")


Artifact = Annotated[
    PostgreSQLArtifact | MariaDBArtifact | SQLiteArtifact,
    Field(discriminator="kind"),
]
ARTIFACT_ADAPTER: TypeAdapter[Artifact] = TypeAdapter(Artifact)


def load_artifact(path: Path) -> Artifact:
    return ARTIFACT_ADAPTER.validate_json(path.read_text(encoding="utf-8"))
