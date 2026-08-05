import json
from pathlib import Path

from beast_storage_observability.cli import disk_bay_main
from beast_storage_observability.disk_bays import DiskBayExporter
from tests.metrics import text_samples


class FakeLsbkSource:
    def __init__(self, serials: dict[str, str] | None = None) -> None:
        self._serials = serials or {}

    def collect(self) -> dict[str, str]:
        return dict(self._serials)


def test_exports_visible_mapped_disks_from_lsblk(tmp_path: Path) -> None:
    source = FakeLsbkSource({"SERIAL-1": "sda", "UNMAPPED": "sdb"})
    bay_map = tmp_path / "bay-map.json"
    bay_map.write_text(
        json.dumps(
            [
                {
                    "serial": "SERIAL-1",
                    "bay": "3",
                    "row": "3",
                    "col": "1",
                    "model": "MODEL-1",
                },
                {
                    "serial": "MISSING",
                    "bay": "4",
                    "row": "4",
                    "col": "1",
                    "model": "MODEL-2",
                },
            ]
        ),
        encoding="utf-8",
    )
    output = tmp_path / "disk-bays.prom"

    assert (
        disk_bay_main(
            ["--bay-map", str(bay_map), "--output-file", str(output)],
            DiskBayExporter(source),
        )
        == 0
    )

    samples = text_samples(output.read_text())["host_observability_disk_bay_info"]
    assert len(samples) == 1
    assert samples[0][0] == {
        "device": "sda",
        "bay": "3",
        "bay_row": "3",
        "bay_col": "1",
        "serial": "SERIAL-1",
        "model": "MODEL-1",
    }
    assert samples[0][1] == 1
    assert output.stat().st_mode & 0o777 == 0o644
