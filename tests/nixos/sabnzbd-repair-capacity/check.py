"""Repair recoverable gaps, but bound downloads for impossible PAR2 repairs."""

import json
import sys
from pathlib import Path

from sabnzbd_test import api, wait_for


def download(nzb: Path):
    added = api("addlocalfile", name=str(nzb), pp=1)
    assert added["status"], added
    job_id = added["nzo_ids"][0]

    def finished():
        snapshot = api("history", nzo_ids=job_id)["history"]
        slot = next(iter(snapshot["slots"]), None)
        if slot and slot["status"] in ("Completed", "Failed") and snapshot["ppslots"] == 0:
            return slot
        return None

    return wait_for(finished, f"{nzb.stem} to finish", timeout=60)


def main() -> None:
    fixtures = Path(sys.argv[1])
    manifest = json.loads((fixtures / "manifest.json").read_text())

    for case in ("repairable", "understated"):
        repaired = download(fixtures / case / f"{case}.nzb")
        assert repaired["status"] == "Completed", repaired
        for name in manifest[case]["payloads"]:
            actual = Path(repaired["storage"])
            if actual.is_dir():
                actual /= name
            expected = fixtures / case / name
            assert actual.read_bytes() == expected.read_bytes(), actual
        print(f"{case}: NZB gaps were restored despite misleading PAR2 names", flush=True)

    failed = download(fixtures / "unrepairable" / "unrepairable.nzb")
    assert failed["status"] == "Failed", failed
    assert "not enough repair blocks" in failed["fail_message"].lower(), failed
    downloaded = failed["downloaded"]
    budget = manifest["unrepairable"]["download_budget"]
    assert downloaded <= budget, (
        f"SABnzbd downloaded {downloaded} bytes for an impossible repair; "
        f"{budget} bytes allow the listed payload and all recovery header probes"
    )
    print("Unrepairable NZB failed without fetching unnecessary recovery bodies", flush=True)


if __name__ == "__main__":
    main()
