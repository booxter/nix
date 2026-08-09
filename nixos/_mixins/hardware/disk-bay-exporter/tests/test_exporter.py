import json
from pathlib import Path

from disk_bay_exporter.cli import main
from disk_bay_exporter.exporter import CommandResult, DiskBayExporter, LsblkSource
from prometheus_client.parser import text_string_to_metric_families


class FakeSerialDeviceSource:
    def __init__(self, serials: dict[str, str] | None = None) -> None:
        self._serials = serials or {}

    def collect(self) -> dict[str, str]:
        return dict(self._serials)


class FakeCommandRunner:
    def __init__(self, result: CommandResult) -> None:
        self._result = result

    def run(self, args: list[str]) -> CommandResult:
        return self._result


def samples(text: str, metric_name: str) -> list[tuple[dict[str, str], float]]:
    return [
        (sample.labels, sample.value)
        for family in text_string_to_metric_families(text)
        for sample in family.samples
        if sample.name == metric_name
    ]


def test_exports_visible_mapped_disks(tmp_path: Path) -> None:
    source = FakeSerialDeviceSource({"SERIAL-1": "sda", "UNMAPPED": "sdb"})
    bay_map = tmp_path / "bay-map.json"
    bay_map.write_text(
        json.dumps(
            [
                {
                    "serial": "SERIAL-1",
                    "bay": 3,
                    "row": 3,
                    "col": 1,
                    "model": "MODEL-1",
                },
                {
                    "serial": "MISSING",
                    "bay": 4,
                    "row": 4,
                    "col": 1,
                    "model": "MODEL-2",
                },
            ]
        ),
        encoding="utf-8",
    )
    output = tmp_path / "disk-bays.prom"

    assert (
        main(
            ["--bay-map", str(bay_map), "--output-file", str(output)],
            DiskBayExporter(source),
        )
        == 0
    )

    metric_samples = samples(output.read_text(), "host_observability_disk_bay_info")
    assert metric_samples == [
        (
            {
                "device": "sda",
                "bay": "3",
                "bay_row": "3",
                "bay_col": "1",
                "serial": "SERIAL-1",
                "model": "MODEL-1",
            },
            1,
        )
    ]
    assert output.stat().st_mode & 0o777 == 0o644


def test_lsblk_source_parses_serials() -> None:
    source = LsblkSource(
        FakeCommandRunner(CommandResult(returncode=0, stdout="sda SERIAL-1\nsdb\nsdc SERIAL-3\n"))
    )

    assert source.collect() == {"SERIAL-1": "sda", "SERIAL-3": "sdc"}


def test_lsblk_source_ignores_failed_command() -> None:
    source = LsblkSource(FakeCommandRunner(CommandResult(returncode=1, stdout="sda SERIAL-1\n")))

    assert source.collect() == {}


def test_cli_reports_invalid_mapping(tmp_path: Path) -> None:
    bay_map = tmp_path / "bay-map.json"
    bay_map.write_text("not JSON", encoding="utf-8")

    assert (
        main(
            ["--bay-map", str(bay_map), "--output-file", str(tmp_path / "metrics.prom")],
            DiskBayExporter(FakeSerialDeviceSource()),
        )
        == 1
    )
