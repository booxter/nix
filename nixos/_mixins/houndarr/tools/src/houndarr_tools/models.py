from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool

Interface = Literal["lidarr", "radarr", "readarr", "sonarr", "whisparr-v2", "whisparr-v3"]
SearchMode = Literal["item", "context"]
Value = str | int | bool


class InstanceStatus(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    enabled: StrictBool | None = False
    active_error: StrictBool | None = False


class StatusResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    instances: tuple[InstanceStatus, ...]


@dataclass(frozen=True)
class StatusSnapshot:
    timestamp: float
    ok: bool
    enabled_instances: int
    active_error_instances: int


class ApiKeyCredential(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    name: str = Field(min_length=1)
    format: Literal["xml-element"]
    field: str = Field(min_length=1)


class ManagedPolicy(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    missing_enabled: bool | None = None
    batch_size: int | None = Field(default=None, ge=1)
    sleep_interval_mins: int | None = Field(default=None, ge=1)
    hourly_cap: int | None = Field(default=None, ge=0)
    cooldown_days: int | None = Field(default=None, ge=0)
    post_release_grace_hrs: int | None = Field(default=None, ge=0)
    missing_hot_retry_window_hrs: int | None = Field(default=None, ge=0)
    missing_hot_retry_interval_hrs: int | None = Field(default=None, ge=1)
    queue_limit: int | None = Field(default=None, ge=0)
    missing_search_mode: SearchMode | None = None
    cutoff_enabled: bool | None = None
    cutoff_batch_size: int | None = Field(default=None, ge=1)
    cutoff_cooldown_days: int | None = Field(default=None, ge=0)
    cutoff_hourly_cap: int | None = Field(default=None, ge=0)
    upgrade_enabled: bool | None = None
    upgrade_batch_size: int | None = Field(default=None, ge=1)
    upgrade_cooldown_days: int | None = Field(default=None, ge=7)
    upgrade_hourly_cap: int | None = Field(default=None, ge=0)
    upgrade_search_mode: SearchMode | None = None
    upgrade_series_window_size: int | None = Field(default=None, ge=1)
    allowed_time_window: str | None = None
    search_order: Literal["chronological", "random"] | None = None
    tag_filter_include: tuple[str, ...] | None = None
    tag_filter_exclude: tuple[str, ...] | None = None


class DesiredInstance(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    key: str = Field(min_length=1)
    display_name: str = Field(alias="displayName", min_length=1)
    interface: Interface
    url: str = Field(min_length=1)
    enabled: bool
    credential: ApiKeyCredential
    policy: ManagedPolicy | None


class ReconcileConfiguration(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    instances: tuple[DesiredInstance, ...]


@dataclass(frozen=True)
class CurrentInstance:
    id: int
    name: str
    interface: Interface
    url: str
    api_key: str
    enabled: bool
    values: dict[str, Value]
