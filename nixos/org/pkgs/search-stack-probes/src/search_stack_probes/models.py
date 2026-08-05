from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, RootModel, StrictBool

NonNegativeInt = Annotated[int, Field(ge=0)]


class HealthResponse(RootModel[dict[str, object]]):
    pass


class ConnectionResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    paperless_connected: StrictBool = False
    vector_store_initialized: StrictBool = False


class SyncResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    paperless_documents: NonNegativeInt = 0
    chroma_chunks: NonNegativeInt = 0
    bulk_sync_limit: NonNegativeInt | None = None


class SearxResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    results: list[dict[str, object]]


@dataclass(frozen=True)
class SearchlessSnapshot:
    timestamp: float
    health_success: bool
    test_connection_success: bool
    sync_status_success: bool
    paperless_connected: bool
    vector_store_initialized: bool
    paperless_documents: int
    chroma_chunks: int
    bulk_sync_limit: int

    @property
    def collection_success(self) -> bool:
        return self.health_success and self.test_connection_success and self.sync_status_success


@dataclass(frozen=True)
class SearxSnapshot:
    timestamp: float
    ok: bool
    duration: float
    http_status: int
    transport_error: bool
    results: int
