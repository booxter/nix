from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, JsonValue, field_validator
from pydantic.alias_generators import to_camel


class ApiModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, extra="ignore")


class RadarrQueueRecord(ApiModel):
    id: int | None = None
    download_id: str = ""
    output_path: Path | None = None
    title: str = ""
    status: str = ""
    protocol: str = ""
    movie_id: int = 0
    tracked_download_status: str = ""
    tracked_download_state: str = ""
    quality: dict[str, JsonValue] = Field(default_factory=dict)

    @field_validator("protocol", mode="before")
    @classmethod
    def normalize_protocol(cls, value: object) -> object:
        name = getattr(value, "name", None)
        return name.lower() if isinstance(name, str) else value


class RadarrMovie(ApiModel):
    id: int
    title: str
    year: int
    runtime: int


class Rejection(ApiModel):
    reason: str = "rejected"


class RadarrManualImportCandidate(ApiModel):
    path: Path
    movie: RadarrMovie
    quality: dict[str, JsonValue] = Field(default_factory=dict)
    languages: list[dict[str, JsonValue]] = Field(default_factory=list)
    release_group: str = ""
    download_id: str = ""
    rejections: list[Rejection] = Field(default_factory=list)


class RadarrManualImportFile(ApiModel):
    path: Path
    movie_id: int
    quality: dict[str, JsonValue]
    languages: list[dict[str, JsonValue]] = Field(default_factory=list)
    release_group: str = ""
    download_id: str
    indexer_flags: int = 0


class CommandStatus(ApiModel):
    id: int
    status: str = ""
    message: str = ""
