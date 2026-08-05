from __future__ import annotations

from typing import TypeVar

import httpx
from pydantic import BaseModel, ValidationError

from .models import (
    ConnectionResponse,
    HealthResponse,
    SearchlessSnapshot,
    SyncResponse,
)

ResponseModel = TypeVar("ResponseModel", bound=BaseModel)


def _get_model(
    client: httpx.Client,
    path: str,
    model: type[ResponseModel],
) -> ResponseModel | None:
    try:
        response = client.get(path)
        response.raise_for_status()
        return model.model_validate(response.json())
    except (httpx.HTTPError, ValueError, ValidationError):
        return None


def collect_searchless(client: httpx.Client, *, now: float) -> SearchlessSnapshot:
    health = _get_model(client, "/health", HealthResponse)
    connection = _get_model(client, "/test-connection", ConnectionResponse)
    sync = _get_model(client, "/sync/status", SyncResponse)
    return SearchlessSnapshot(
        timestamp=now,
        health_success=health is not None,
        test_connection_success=connection is not None,
        sync_status_success=sync is not None,
        paperless_connected=connection.paperless_connected if connection is not None else False,
        vector_store_initialized=(
            connection.vector_store_initialized if connection is not None else False
        ),
        paperless_documents=sync.paperless_documents if sync is not None else 0,
        chroma_chunks=sync.chroma_chunks if sync is not None else 0,
        bulk_sync_limit=(sync.bulk_sync_limit or 0) if sync is not None else 0,
    )
