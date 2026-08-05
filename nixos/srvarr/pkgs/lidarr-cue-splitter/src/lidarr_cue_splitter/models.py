from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, JsonValue, field_validator
from pydantic.alias_generators import to_camel


class ApiModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, extra="ignore")


class QueueRecord(ApiModel):
    id: int | None = None
    download_id: str = ""
    output_path: Path | None = None
    title: str = ""
    status: str = ""
    protocol: str = ""
    artist_id: int = 0
    album_id: int = 0

    @field_validator("protocol", mode="before")
    @classmethod
    def normalize_protocol(cls, value: object) -> object:
        if isinstance(value, Enum):
            return value.name.lower()
        return value


class EntityReference(ApiModel):
    id: int = 0


class Rejection(ApiModel):
    reason: str = "rejected"


class ManualImportCandidate(ApiModel):
    path: Path
    artist: EntityReference = Field(default_factory=EntityReference)
    album: EntityReference = Field(default_factory=EntityReference)
    album_release_id: int = 0
    tracks: list[EntityReference] = Field(default_factory=list)
    quality: dict[str, JsonValue] = Field(default_factory=dict)
    download_id: str = ""
    disable_release_switching: bool = False
    rejections: list[Rejection] = Field(default_factory=list)


class ManualImportFile(ApiModel):
    path: Path
    artist_id: int
    album_id: int
    album_release_id: int
    track_ids: list[int]
    quality: dict[str, JsonValue]
    indexer_flags: int = 0
    download_id: str
    disable_release_switching: bool


class CommandStatus(ApiModel):
    id: int
    status: str = ""
    message: str = ""


class UnflacAudio(ApiModel):
    path: Path
    tracks: list[object]


class UnflacInput(ApiModel):
    audio: list[UnflacAudio] = Field(default_factory=list)


@dataclass(frozen=True)
class CueSummary:
    cue: Path
    audio_files: tuple[Path, ...]
    track_count: int
    eligible: bool
