from __future__ import annotations

from pathlib import Path

from prometheus_client import CollectorRegistry, Gauge, write_to_textfile

from .models import SearchlessSnapshot, SearxSnapshot


def _gauge(registry: CollectorRegistry, name: str, documentation: str, value: float) -> None:
    Gauge(name, documentation, registry=registry).set(value)


def searchless_registry(snapshot: SearchlessSnapshot) -> CollectorRegistry:
    registry = CollectorRegistry()
    for name, documentation, value in (
        (
            "searchless_metrics_collection_success",
            "Whether the most recent Searchless API metrics collection completed successfully.",
            snapshot.collection_success,
        ),
        (
            "searchless_metrics_collection_timestamp_seconds",
            "Unix timestamp of the most recent Searchless API metrics collection.",
            snapshot.timestamp,
        ),
        (
            "searchless_health_success",
            "Whether the most recent Searchless health endpoint probe succeeded.",
            snapshot.health_success,
        ),
        (
            "searchless_test_connection_success",
            "Whether the most recent Searchless test-connection API probe succeeded.",
            snapshot.test_connection_success,
        ),
        (
            "searchless_sync_status_success",
            "Whether the most recent Searchless sync status API probe succeeded.",
            snapshot.sync_status_success,
        ),
        (
            "searchless_paperless_connected",
            "Whether Searchless can query the Paperless API.",
            snapshot.paperless_connected,
        ),
        (
            "searchless_vector_store_initialized",
            "Whether Searchless can initialize the Chroma vector store.",
            snapshot.vector_store_initialized,
        ),
        (
            "searchless_paperless_documents",
            "Number of documents visible to Searchless in Paperless.",
            snapshot.paperless_documents,
        ),
        (
            "searchless_chroma_chunks",
            "Number of chunks stored in Chroma for Searchless retrieval.",
            snapshot.chroma_chunks,
        ),
        (
            "searchless_bulk_sync_limit",
            "Configured bulk sync document limit. Zero means unlimited.",
            snapshot.bulk_sync_limit,
        ),
    ):
        _gauge(registry, name, documentation, float(value))
    return registry


def searx_registry(snapshot: SearxSnapshot) -> CollectorRegistry:
    registry = CollectorRegistry()
    prefix = "host_observability_openwebui_searxng_probe"
    for suffix, documentation, value in (
        (
            "ok",
            "Whether the most recent Open WebUI SearXNG dependency probe succeeded.",
            snapshot.ok,
        ),
        (
            "timestamp_seconds",
            "Unix timestamp of the most recent Open WebUI SearXNG dependency probe.",
            snapshot.timestamp,
        ),
        (
            "duration_seconds",
            "Duration of the most recent Open WebUI SearXNG dependency probe.",
            snapshot.duration,
        ),
        (
            "http_status_code",
            "HTTP status code returned by the most recent Open WebUI SearXNG dependency probe.",
            snapshot.http_status,
        ),
        (
            # Preserve the old curl-specific series name for query
            # compatibility even though HTTP is now handled in-process.
            "curl_exit_code",
            "Transport exit code from the most recent Open WebUI SearXNG dependency probe.",
            snapshot.transport_error,
        ),
        (
            "results",
            "Search result count returned by the most recent Open WebUI SearXNG dependency probe.",
            snapshot.results,
        ),
    ):
        _gauge(registry, f"{prefix}_{suffix}", documentation, float(value))
    return registry


def write_registry(path: Path, registry: CollectorRegistry) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_to_textfile(str(path), registry)
