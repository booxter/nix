from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import pytest
from prometheus_client import generate_latest
from prometheus_client.parser import text_string_to_metric_families

from beast_storage_observability.hba import (
    HbaError,
    HbaExporter,
    HbaMetrics,
    StorcliSource,
    SubprocessStorcliSource,
)
from beast_storage_observability.models import BayMapping, StorcliDocument


def storcli_document(*, command_status: str = "Success") -> StorcliDocument:
    drive_key = "Drive /c0/e8/s1"
    return StorcliDocument.model_validate(
        {
            "Controllers": [
                {
                    "Command Status": {"Controller": 0, "Status": command_status},
                    "Response Data": {
                        "Basics": {
                            "Controller": 0,
                            "Adapter Type": "SAS3224",
                            "Model": "SAS9305-24i",
                            "Serial Number": "controller-serial",
                        },
                        "Version": {
                            "Driver Name": "mpi3mr",
                            "Firmware Version": "16.00.12.00",
                        },
                        "Status": {
                            "Controller Status": "Optimal",
                            "Memory Correctable Errors": 2,
                            "Memory Uncorrectable Errors": 0,
                        },
                        "HwCfg": {
                            "Backend Port Count": 24,
                            "ROC temperature(Degree Celcius)": "54",
                        },
                        "Physical Device Information": {
                            drive_key: [
                                {
                                    "EID:Slt": "8:1",
                                    "DID": 5,
                                    "Intf": "SAS",
                                    "Med": "HDD",
                                    "Model": "fallback-model",
                                    "State": "Onln",
                                }
                            ],
                            f"{drive_key} - Detailed Information": {
                                f"{drive_key} State": {
                                    "Media Error Count": 1,
                                    "Other Error Count": 2,
                                    "Predictive Failure Count": 3,
                                    "S.M.A.R.T alert flagged by drive": "No",
                                },
                                f"{drive_key} Device attributes": {
                                    "SN": "visible-serial",
                                    "Model Number": "ST24000NM000H",
                                    "Firmware Revision": "SN02",
                                    "Link Speed": "12.0Gb/s",
                                },
                                f"{drive_key} Policies/Settings": {
                                    "Connected Port Number": "Port 9"
                                },
                            },
                        },
                    },
                }
            ]
        }
    )


def metric_samples(metrics: HbaMetrics) -> dict[str, list[tuple[dict[str, str], float]]]:
    parsed: dict[str, list[tuple[dict[str, str], float]]] = {}
    for family in text_string_to_metric_families(generate_latest(metrics.registry).decode()):
        for sample in family.samples:
            parsed.setdefault(sample.name, []).append((sample.labels, sample.value))
    return parsed


def value(
    samples: dict[str, list[tuple[dict[str, str], float]]],
    name: str,
    **expected_labels: str,
) -> float:
    matches = [
        sample_value
        for labels, sample_value in samples[name]
        if all(labels.get(key) == label for key, label in expected_labels.items())
    ]
    assert len(matches) == 1
    return matches[0]


def test_collects_typed_controller_and_drive_metrics() -> None:
    metrics = HbaMetrics()
    metrics.collect(
        storcli_document(),
        {
            "visible-serial": BayMapping(
                serial="visible-serial", bay=1, row=0, col=0, model="ST24000NM000H"
            ),
            "missing-serial": BayMapping(
                serial="missing-serial", bay=2, row=0, col=1, model="ST24000NM000H"
            ),
        },
    )

    samples = metric_samples(metrics)
    assert value(samples, "host_observability_hba_collect_success", controller="0") == 1
    assert (
        value(
            samples,
            "host_observability_hba_temperature_celsius",
            controller="0",
            sensor="roc",
        )
        == 54
    )
    assert value(samples, "host_observability_hba_healthy", controller="0") == 1
    assert (
        value(
            samples,
            "host_observability_hba_memory_correctable_errors",
            controller="0",
        )
        == 2
    )
    assert (
        value(
            samples,
            "host_observability_hba_memory_uncorrectable_errors",
            controller="0",
        )
        == 0
    )
    assert value(samples, "host_observability_hba_physical_drives", controller="0") == 1
    assert (
        value(
            samples,
            "host_observability_hba_drive_link_speed_gbps",
            serial="visible-serial",
        )
        == 12
    )
    assert (
        value(
            samples,
            "host_observability_hba_drive_connected_port",
            serial="visible-serial",
        )
        == 9
    )
    assert (
        value(
            samples,
            "host_observability_hba_drive_media_errors",
            serial="visible-serial",
        )
        == 1
    )
    assert (
        value(
            samples,
            "host_observability_hba_drive_predictive_errors",
            serial="visible-serial",
        )
        == 3
    )
    assert (
        value(
            samples,
            "host_observability_hba_drive_smart_alerted",
            serial="visible-serial",
        )
        == 0
    )
    assert (
        value(
            samples,
            "host_observability_hba_drive_visible",
            serial="missing-serial",
            bay="2",
        )
        == 0
    )


def test_failed_controller_marks_collection_unavailable() -> None:
    metrics = HbaMetrics()
    metrics.collect(storcli_document(command_status="Failure"), {})

    samples = metric_samples(metrics)
    assert value(samples, "host_observability_hba_collect_success", controller="0") == 0
    assert value(samples, "host_observability_hba_collect_success", controller="all") == 0


@dataclass(frozen=True)
class StaticSource(StorcliSource):
    document: StorcliDocument

    def collect(self) -> StorcliDocument:
        return self.document


@dataclass(frozen=True)
class FailingSource(StorcliSource):
    def collect(self) -> StorcliDocument:
        raise HbaError("controller unavailable")


def write_bay_map(path: Path) -> None:
    path.write_text(
        json.dumps([{"serial": "visible-serial", "bay": 1, "row": 0, "col": 0}]),
        encoding="utf-8",
    )


def test_exporter_atomically_publishes_metrics(tmp_path: Path) -> None:
    bay_map = tmp_path / "bay-map.json"
    output = tmp_path / "textfile" / "hba.prom"
    write_bay_map(bay_map)

    HbaExporter(StaticSource(storcli_document())).run(bay_map, output)

    samples = {
        sample.name: sample.value
        for family in text_string_to_metric_families(output.read_text(encoding="utf-8"))
        for sample in family.samples
        if sample.name == "host_observability_hba_collect_success"
        and sample.labels == {"controller": "0"}
    }
    assert samples == {"host_observability_hba_collect_success": 1}
    assert output.stat().st_mode & 0o777 == 0o644


def test_exporter_publishes_failure_metric_before_returning_error(tmp_path: Path) -> None:
    bay_map = tmp_path / "bay-map.json"
    output = tmp_path / "hba.prom"
    write_bay_map(bay_map)

    with pytest.raises(HbaError, match="controller unavailable"):
        HbaExporter(FailingSource()).run(bay_map, output)

    samples = [
        sample
        for family in text_string_to_metric_families(output.read_text(encoding="utf-8"))
        for sample in family.samples
        if sample.name == "host_observability_hba_collect_success"
    ]
    assert [(sample.labels, sample.value) for sample in samples] == [({"controller": "all"}, 0)]


def test_subprocess_source_reports_missing_storcli() -> None:
    with pytest.raises(HbaError, match="could not execute StorCLI"):
        SubprocessStorcliSource("beast-storcli-does-not-exist").collect()
