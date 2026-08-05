from __future__ import annotations

import argparse
import time
import urllib.parse
import urllib.request
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol, cast

from prometheus_client import CollectorRegistry, Gauge
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .textfile import write


class ModelDetails(BaseModel):
    model_config = ConfigDict(extra="ignore")

    context_length: int | None = None
    embedding_length: int | None = None
    family: str = ""
    format: str = ""
    parameter_size: str = ""
    quantization_level: str = ""


class OllamaModel(BaseModel):
    model_config = ConfigDict(extra="ignore")

    capabilities: list[str] = Field(default_factory=list)
    details: ModelDetails = Field(default_factory=ModelDetails)
    expires_at: datetime | None = None
    model: str | None = None
    modified_at: datetime | None = None
    name: str | None = None
    size: int | None = None
    size_vram: int | None = None

    @property
    def label(self) -> str:
        return self.model or self.name or "unknown"


class VersionResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")

    version: str = ""


class ModelsResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")

    models: list[OllamaModel] = Field(default_factory=list)


@dataclass(frozen=True)
class Snapshot:
    models: tuple[OllamaModel, ...]
    running_models: tuple[OllamaModel, ...]
    version: str


class JsonTransport(Protocol):
    def get(self, path: str) -> bytes: ...


class SnapshotSource(Protocol):
    def fetch(self) -> Snapshot: ...


@dataclass(frozen=True)
class HttpTransport:
    base_url: str
    timeout: float

    def get(self, path: str) -> bytes:
        url = urllib.parse.urljoin(self.base_url.rstrip("/") + "/", path.lstrip("/"))
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return cast(bytes, response.read())


@dataclass(frozen=True)
class OllamaSource:
    transport: JsonTransport

    def fetch(self) -> Snapshot:
        version = VersionResponse.model_validate_json(self.transport.get("/api/version"))
        models = ModelsResponse.model_validate_json(self.transport.get("/api/tags"))
        running = ModelsResponse.model_validate_json(self.transport.get("/api/ps"))
        return Snapshot(tuple(models.models), tuple(running.models), version.version)


def _gauge(
    registry: CollectorRegistry,
    name: str,
    documentation: str,
    labels: Sequence[str] = (),
) -> Gauge:
    return Gauge(name, documentation, labelnames=labels, registry=registry)


def _model_labels(model: OllamaModel) -> tuple[str, str, str, str, str]:
    return (
        model.label,
        model.details.family,
        model.details.format,
        model.details.parameter_size,
        model.details.quantization_level,
    )


def _timestamp(value: datetime | None) -> float | None:
    return value.timestamp() if value is not None else None


def success_registry(snapshot: Snapshot, duration: float) -> CollectorRegistry:
    registry = CollectorRegistry()
    _gauge(
        registry,
        "host_observability_ollama_collector_ok",
        "Whether the latest Ollama metrics collection iteration succeeded.",
    ).set(1)
    _gauge(
        registry,
        "host_observability_ollama_collector_duration_seconds",
        "Wall-clock duration of the latest Ollama metrics collection iteration.",
    ).set(duration)
    _gauge(
        registry,
        "host_observability_ollama_up",
        "Whether the local Ollama API is reachable.",
    ).set(1)
    _gauge(
        registry,
        "host_observability_ollama_info",
        "Static Ollama service information.",
        ("version",),
    ).labels(snapshot.version).set(1)
    _gauge(
        registry,
        "host_observability_ollama_models",
        "Number of locally installed Ollama models.",
    ).set(len(snapshot.models))
    _gauge(
        registry,
        "host_observability_ollama_running_models",
        "Number of currently loaded Ollama models.",
    ).set(len(snapshot.running_models))

    info = _gauge(
        registry,
        "host_observability_ollama_model_info",
        "Static Ollama model information.",
        ("model", "family", "format", "parameter_size", "quantization_level"),
    )
    size = _gauge(
        registry,
        "host_observability_ollama_model_size_bytes",
        "Local Ollama model size in bytes.",
        ("model",),
    )
    modified = _gauge(
        registry,
        "host_observability_ollama_model_modified_timestamp_seconds",
        "Unix timestamp when the local Ollama model was last modified.",
        ("model",),
    )
    context = _gauge(
        registry,
        "host_observability_ollama_model_context_length",
        "Ollama model context length.",
        ("model",),
    )
    embedding = _gauge(
        registry,
        "host_observability_ollama_model_embedding_length",
        "Ollama model embedding length.",
        ("model",),
    )
    capability = _gauge(
        registry,
        "host_observability_ollama_model_capability",
        "Ollama model capability flag.",
        ("model", "capability"),
    )
    for model in snapshot.models:
        info.labels(*_model_labels(model)).set(1)
        if model.size is not None:
            size.labels(model.label).set(model.size)
        if (timestamp := _timestamp(model.modified_at)) is not None:
            modified.labels(model.label).set(timestamp)
        if model.details.context_length is not None:
            context.labels(model.label).set(model.details.context_length)
        if model.details.embedding_length is not None:
            embedding.labels(model.label).set(model.details.embedding_length)
        for value in model.capabilities:
            capability.labels(model.label, value).set(1)

    running_info = _gauge(
        registry,
        "host_observability_ollama_running_model_info",
        "Currently loaded Ollama model information.",
        ("model", "family", "format", "parameter_size", "quantization_level"),
    )
    running_size = _gauge(
        registry,
        "host_observability_ollama_running_model_size_bytes",
        "Loaded Ollama model total size in bytes.",
        ("model",),
    )
    running_vram = _gauge(
        registry,
        "host_observability_ollama_running_model_vram_size_bytes",
        "Loaded Ollama model VRAM size in bytes.",
        ("model",),
    )
    expires = _gauge(
        registry,
        "host_observability_ollama_running_model_expires_timestamp_seconds",
        "Unix timestamp when the loaded Ollama model is scheduled to unload.",
        ("model",),
    )
    for model in snapshot.running_models:
        running_info.labels(*_model_labels(model)).set(1)
        if model.size is not None:
            running_size.labels(model.label).set(model.size)
        if model.size_vram is not None:
            running_vram.labels(model.label).set(model.size_vram)
        if (timestamp := _timestamp(model.expires_at)) is not None:
            expires.labels(model.label).set(timestamp)
    return registry


def failure_registry(duration: float) -> CollectorRegistry:
    registry = CollectorRegistry()
    _gauge(
        registry,
        "host_observability_ollama_collector_ok",
        "Whether the latest Ollama metrics collection iteration succeeded.",
    ).set(0)
    _gauge(
        registry,
        "host_observability_ollama_collector_duration_seconds",
        "Wall-clock duration of the latest Ollama metrics collection iteration.",
    ).set(duration)
    _gauge(
        registry,
        "host_observability_ollama_up",
        "Whether the local Ollama API is reachable.",
    ).set(0)
    return registry


@dataclass(frozen=True)
class Arguments:
    base_url: str
    output: str
    timeout: float


def collect(
    source: SnapshotSource,
    clock: Callable[[], float] = time.monotonic,
) -> CollectorRegistry:
    started = clock()
    try:
        snapshot = source.fetch()
    except (OSError, ValidationError):
        return failure_registry(clock() - started)
    return success_registry(snapshot, clock() - started)


def parse_arguments(argv: Sequence[str] | None = None) -> Arguments:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:11434")
    parser.add_argument("--output", default="-")
    parser.add_argument("--timeout", type=float, default=10)
    parsed = parser.parse_args(argv)
    return Arguments(base_url=parsed.base_url, output=parsed.output, timeout=parsed.timeout)


def main(argv: Sequence[str] | None = None) -> None:
    arguments = parse_arguments(argv)
    source = OllamaSource(HttpTransport(arguments.base_url, arguments.timeout))
    write(collect(source), arguments.output)
