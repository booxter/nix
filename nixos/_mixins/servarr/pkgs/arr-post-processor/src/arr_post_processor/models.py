from __future__ import annotations

from enum import Enum
from pathlib import Path
from typing import Annotated

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
    tracked_download_status: str = ""
    tracked_download_state: str = ""
    status_messages: list[StatusMessage] = Field(default_factory=list)

    @field_validator("protocol", mode="before")
    @classmethod
    def normalize_protocol(cls, value: object) -> object:
        if isinstance(value, Enum):
            return value.name.lower()
        return value


class EntityReference(ApiModel):
    id: int = 0


class StatusMessage(ApiModel):
    title: str = ""
    messages: list[str] = Field(default_factory=list)


TrackNumber = Annotated[int, Field(ge=1)] | Annotated[str, Field(min_length=1)]


class LidarrTrack(ApiModel):
    id: int = Field(gt=0)
    title: str = Field(min_length=1)
    medium_number: int = Field(ge=1)
    track_number: TrackNumber
    absolute_track_number: int = Field(ge=0)
    duration: int = Field(ge=0)


class LidarrRelease(ApiModel):
    id: int = Field(gt=0)
    title: str = Field(min_length=1)
    disambiguation: str = ""
    format: str = ""
    status: str = ""
    monitored: bool = False
    medium_count: int = Field(ge=0)
    track_count: int = Field(ge=0)
    duration: int = Field(ge=0)


class LidarrAlbum(ApiModel):
    id: int = Field(gt=0)
    title: str = Field(min_length=1)
    artist_id: int = Field(gt=0)
    artist: LidarrArtist
    any_release_ok: bool = False
    releases: list[LidarrRelease] = Field(default_factory=list)


class LidarrArtist(ApiModel):
    id: int = Field(gt=0)
    artist_name: str = Field(min_length=1)


class CatalogRelease(BaseModel):
    model_config = ConfigDict(extra="forbid")

    release: LidarrRelease
    tracks: list[LidarrTrack]


class AlbumCatalog(BaseModel):
    model_config = ConfigDict(extra="forbid")

    album: LidarrAlbum
    releases: list[CatalogRelease]


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
