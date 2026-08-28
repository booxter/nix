from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StartupStatus(StrEnum):
    READY = "ready"
    FAILED = "failed"
    CANCELLED = "cancelled"


REAUTHENTICATION_REQUIRED = "reauthenticationRequired"


@dataclass(frozen=True)
class ServerStartup:
    name: str
    status: StartupStatus
    error: str | None = None
    failure_reason: str | None = None

    @property
    def requires_reauthentication(self) -> bool:
        return (
            self.status is StartupStatus.FAILED and self.failure_reason == REAUTHENTICATION_REQUIRED
        )


class RpcEnvelope(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int | str | None = None
    method: str | None = None


class RpcError(BaseModel):
    model_config = ConfigDict(extra="ignore")

    message: str


class ThreadStartResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: Literal[2]
    error: RpcError | None = None


class StartupParameters(BaseModel):
    model_config = ConfigDict(extra="ignore")

    name: str
    status: Literal["starting", "ready", "failed", "cancelled"]
    error: str | None = None
    failure_reason: str | None = Field(default=None, alias="failureReason")


class StartupNotification(BaseModel):
    model_config = ConfigDict(extra="ignore")

    method: Literal["mcpServer/startupStatus/updated"]
    params: StartupParameters
