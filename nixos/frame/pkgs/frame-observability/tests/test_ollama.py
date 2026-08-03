from __future__ import annotations

import json
import os
from collections.abc import Iterator
from pathlib import Path

import pytest
from prometheus_client import CollectorRegistry
from prometheus_client.parser import text_string_to_metric_families
from pydantic import ValidationError

from frame_observability.ollama import (
    Arguments,
    OllamaSource,
    Snapshot,
    collect,
    parse_arguments,
    success_registry,
)
from frame_observability.textfile import render, write


class StaticTransport:
    def __init__(self, responses: dict[str, object]) -> None:
        self.responses = responses
        self.requests: list[str] = []

    def get(self, path: str) -> bytes:
        self.requests.append(path)
        return json.dumps(self.responses[path]).encode()


class StaticSource:
    def __init__(self, snapshot: Snapshot | None = None, error: OSError | None = None) -> None:
        self.snapshot = snapshot
        self.error = error

    def fetch(self) -> Snapshot:
        if self.error is not None:
            raise self.error
        assert self.snapshot is not None
        return self.snapshot


def clock(values: Iterator[float]) -> float:
    return next(values)


def samples(registry: CollectorRegistry) -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    rendered = render(registry).decode()
    result: dict[tuple[str, tuple[tuple[str, str], ...]], float] = {}
    for family in text_string_to_metric_families(rendered):
        for sample in family.samples:
            result[(sample.name, tuple(sorted(sample.labels.items())))] = sample.value
    return result


def test_source_validates_typed_api_responses() -> None:
    transport = StaticTransport(
        {
            "/api/version": {"version": "0.13.5"},
            "/api/tags": {
                "models": [
                    {
                        "model": "qwen:latest",
                        "size": 123,
                        "modified_at": "2026-08-03T12:00:00Z",
                        "details": {
                            "family": "qwen",
                            "format": "gguf",
                            "parameter_size": "7B",
                            "quantization_level": "Q4_K_M",
                            "context_length": 32768,
                            "embedding_length": 3584,
                        },
                        "capabilities": ["completion", "tools"],
                    }
                ]
            },
            "/api/ps": {
                "models": [
                    {
                        "name": "qwen:latest",
                        "size": 100,
                        "size_vram": 80,
                        "expires_at": "2026-08-03T12:05:00Z",
                    }
                ]
            },
        }
    )

    snapshot = OllamaSource(transport).fetch()

    assert transport.requests == ["/api/version", "/api/tags", "/api/ps"]
    assert snapshot.version == "0.13.5"
    assert snapshot.models[0].label == "qwen:latest"
    assert snapshot.models[0].details.context_length == 32768
    assert snapshot.running_models[0].size_vram == 80


def test_source_rejects_invalid_numeric_fields() -> None:
    transport = StaticTransport(
        {
            "/api/version": {"version": "test"},
            "/api/tags": {"models": [{"size": "not-a-number"}]},
            "/api/ps": {"models": []},
        }
    )

    with pytest.raises(ValidationError):
        OllamaSource(transport).fetch()


def test_success_registry_preserves_model_and_runtime_metrics() -> None:
    transport = StaticTransport(
        {
            "/api/version": {"version": "0.13.5"},
            "/api/tags": {
                "models": [
                    {
                        "model": "qwen:latest",
                        "size": 123,
                        "modified_at": 1_700_000_000,
                        "details": {"family": "qwen", "context_length": 32768},
                        "capabilities": ["tools"],
                    }
                ]
            },
            "/api/ps": {
                "models": [
                    {
                        "model": "qwen:latest",
                        "size": 100,
                        "size_vram": 80,
                        "expires_at": 1_700_000_300,
                    }
                ]
            },
        }
    )
    registry = success_registry(OllamaSource(transport).fetch(), 0.25)

    values = samples(registry)

    assert values[("host_observability_ollama_collector_ok", ())] == 1
    assert values[("host_observability_ollama_models", ())] == 1
    assert values[("host_observability_ollama_running_models", ())] == 1
    assert (
        values[("host_observability_ollama_model_size_bytes", (("model", "qwen:latest"),))] == 123
    )
    assert (
        values[
            (
                "host_observability_ollama_model_capability",
                (("capability", "tools"), ("model", "qwen:latest")),
            )
        ]
        == 1
    )
    assert (
        values[
            ("host_observability_ollama_running_model_vram_size_bytes", (("model", "qwen:latest"),))
        ]
        == 80
    )


def test_collection_failure_emits_health_metrics_without_raising() -> None:
    values = iter([10.0, 10.75])
    registry = collect(
        StaticSource(error=OSError("unreachable")),
        lambda: clock(values),
    )

    metrics = samples(registry)
    assert metrics[("host_observability_ollama_collector_ok", ())] == 0
    assert metrics[("host_observability_ollama_up", ())] == 0
    assert metrics[("host_observability_ollama_collector_duration_seconds", ())] == 0.75


def test_textfile_output_is_atomic_and_world_readable(tmp_path: Path) -> None:
    destination = tmp_path / "ollama.prom"
    registry = collect(
        StaticSource(snapshot=Snapshot((), (), "test")),
        lambda: 1.0,
    )

    write(registry, str(destination))

    assert destination.read_text().startswith("# HELP host_observability_ollama_collector_ok")
    assert os.stat(destination).st_mode & 0o777 == 0o644
    assert list(tmp_path.iterdir()) == [destination]


def test_cli_defaults_and_case() -> None:
    arguments = parse_arguments([])

    assert arguments == Arguments("http://127.0.0.1:11434", "-", 10)
