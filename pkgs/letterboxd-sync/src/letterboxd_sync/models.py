from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, StringConstraints

ImdbId = Annotated[str, StringConstraints(pattern=r"^tt[0-9]+$")]


class SyncError(Exception):
    """Safe to display: never include credentials or remote response bodies."""


class Account(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    jellyfin_user: str = Field(min_length=1)
    letterboxd_user: str = Field(pattern=r"^[A-Za-z0-9_]+$")


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")

    jellyfin_url: HttpUrl


class User(BaseModel):
    id: str = Field(alias="Id", pattern=r"^[a-fA-F0-9-]+$")
    name: str = Field(alias="Name")


class UserData(BaseModel):
    played: bool = Field(alias="Played")


class Item(BaseModel):
    id: str = Field(alias="Id")
    kind: str = Field(alias="Type")
    providers: dict[str, str] = Field(alias="ProviderIds", default_factory=dict)
    user_data: UserData = Field(alias="UserData")


class Items(BaseModel):
    items: list[Item] = Field(alias="Items")
    total: int = Field(alias="TotalRecordCount", ge=0)


class Production(BaseModel):
    imdbId: ImdbId
    title: None = None
    originalTitle: None = None
    rating: None = None
    review: None = None
    year: None = None
    type: None = None
    letterboxdURI: None = None
    tmdbId: None = None
    tags: None = None
    watchedDate: None = None
    isICheckMoviesImport: bool = False
    rewatch: bool = False
    creators: list[str] = Field(default_factory=list)


class ImportResult(BaseModel):
    result: bool = Field(strict=True)
