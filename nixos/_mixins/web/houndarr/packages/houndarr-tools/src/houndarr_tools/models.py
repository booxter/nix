from __future__ import annotations

from dataclasses import dataclass

from pydantic import BaseModel, ConfigDict, StrictBool


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
