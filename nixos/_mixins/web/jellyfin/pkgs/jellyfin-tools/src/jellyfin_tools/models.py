from __future__ import annotations

from pathlib import Path

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, RootModel, StrictBool


class NowPlayingItem(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    name: str = Field(default="unknown item", alias="Name")


class PlayState(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    is_paused: StrictBool = Field(default=False, alias="IsPaused")


class Session(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    user_name: str = Field(default="unknown user", alias="UserName")
    now_playing_item: NowPlayingItem | None = Field(default=None, alias="NowPlayingItem")
    play_state: PlayState = Field(default_factory=PlayState, alias="PlayState")


class Sessions(RootModel[tuple[Session, ...]]):
    pass


class BackupManifest(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    path: Path = Field(validation_alias=AliasChoices("Path", "path"))
