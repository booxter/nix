"""Exercise PAR2 search scope through real downloads and repairs."""

import sys
from pathlib import Path

from sabnzbd_test import download


def download_with_log(directory: Path) -> tuple[dict, str]:
    with Path("/var/lib/sabnzbd/logs/sabnzbd.log").open() as log:
        log.seek(0, 2)
        result = download(directory / f"{directory.name}.nzb")
        return result, log.read()


def check_job(directory: Path) -> None:
    expected = next(directory.glob("Episode*.bin"))
    result, output = download_with_log(directory)
    assert result["status"] == "Completed", result
    repaired = Path(result["storage"]) / expected.name
    assert repaired.read_bytes() == expected.read_bytes(), repaired

    # PAR2 reports protected payloads as targets and extra files it scans as files.
    assert f'Target: "{expected.name}" - damaged' in output, "Expected a real PAR2 scan"
    assert 'File: "Other.bin"' not in output, f"Repairing {expected.name} also scanned Other.bin"
    print(f"{expected.name} repaired without scanning Other.bin", flush=True)


def check_shared_prefix(directory: Path) -> None:
    result, output = download_with_log(directory)
    assert result["status"] == "Completed", result
    for name in ("First.bin", "Second.bin"):
        assert (Path(result["storage"]) / name).read_bytes() == (directory / name).read_bytes()
        assert f'Target: "{name}" - damaged' in output, f"Missing repair for {name}"
    extras = [name for name in ("First.bin", "Second.bin") if f'File: "{name}"' in output]
    assert not extras, f"Repair scanned another PAR2 set's payload: {extras}"


def check_spare(directory: Path) -> None:
    result, output = download_with_log(directory)
    assert 'File: "spare.bin" - found' in output, "PAR2 did not recover blocks from spare.bin"
    # Either set can receive the shared name. Preserve the recovery already
    # possible for the other set, even if the whole job ends up in Failed.
    repaired = []
    for name in ("First.bin", "Second.bin"):
        target = Path(result["storage"]) / name
        if target.is_file() and target.read_bytes() == (directory / name).read_bytes():
            repaired.append(name)
    assert repaired, f"Neither payload was recovered from spare.bin: {result}"
    print(f"Recovered {repaired} using spare.bin", flush=True)


if __name__ == "__main__":
    fixtures = Path(sys.argv[1])
    check_job(fixtures / "plain")
    check_job(fixtures / "bracketed")
    check_spare(fixtures / "shared-prefix-spare")
    check_shared_prefix(fixtures / "shared-prefix")
