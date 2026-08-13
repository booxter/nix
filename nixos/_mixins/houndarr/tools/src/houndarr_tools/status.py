from __future__ import annotations

from pathlib import Path

import httpx
from prometheus_client import CollectorRegistry, Gauge, write_to_textfile
from pydantic import ValidationError

from .models import StatusResponse, StatusSnapshot


def collect_status(client: httpx.Client, url: str, *, now: float) -> StatusSnapshot:
    try:
        response = client.get(url, headers={"X-User": "houndarr-monitor"})
        response.raise_for_status()
        status = StatusResponse.model_validate(response.json())
    except (httpx.HTTPError, ValueError, ValidationError):
        return StatusSnapshot(
            timestamp=now,
            ok=False,
            enabled_instances=0,
            active_error_instances=0,
        )
    enabled = tuple(instance for instance in status.instances if instance.enabled is True)
    return StatusSnapshot(
        timestamp=now,
        ok=True,
        enabled_instances=len(enabled),
        active_error_instances=sum(instance.active_error is True for instance in enabled),
    )


def status_registry(snapshot: StatusSnapshot) -> CollectorRegistry:
    registry = CollectorRegistry()
    for name, documentation, value in (
        (
            "host_observability_houndarr_status_ok",
            "Whether the latest Houndarr operational status collection succeeded.",
            snapshot.ok,
        ),
        (
            "host_observability_houndarr_enabled_instances",
            "Number of enabled Houndarr Arr instances.",
            snapshot.enabled_instances,
        ),
        (
            "host_observability_houndarr_active_error_instances",
            "Number of enabled Houndarr Arr instances whose newest cycle result is an error.",
            snapshot.active_error_instances,
        ),
        (
            "host_observability_houndarr_status_timestamp_seconds",
            "Unix timestamp of the latest Houndarr operational status collection.",
            snapshot.timestamp,
        ),
    ):
        Gauge(name, documentation, registry=registry).set(float(value))
    return registry


def write_status(path: Path, snapshot: StatusSnapshot) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_to_textfile(str(path), status_registry(snapshot))
