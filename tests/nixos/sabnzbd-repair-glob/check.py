"""A bracketed PAR2 set should repair without scanning another set's payload."""

import sys
from pathlib import Path

from sabnzbd_test import download


def check_job(directory: Path) -> None:
    expected = next(directory.glob("Episode*.bin"))
    with Path("/var/lib/sabnzbd/logs/sabnzbd.log").open() as log:
        log.seek(0, 2)
        result = download(directory / f"{directory.name}.nzb")
        output = log.read()

    assert result["status"] == "Completed", result
    repaired = Path(result["storage"]) / expected.name
    assert repaired.read_bytes() == expected.read_bytes(), repaired

    # PAR2 reports protected payloads as targets and extra files it scans as files.
    assert f'Target: "{expected.name}" - damaged' in output, "Expected a real PAR2 scan"
    assert 'File: "Other.bin"' not in output, f"Repairing {expected.name} also scanned Other.bin"
    print(f"{expected.name} repaired without scanning Other.bin", flush=True)


if __name__ == "__main__":
    fixtures = Path(sys.argv[1])
    check_job(fixtures / "plain")
    check_job(fixtures / "bracketed")
