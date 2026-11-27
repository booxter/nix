"""A fast NNTP connection must download without waiting for its timeout."""

import sys
import time
from pathlib import Path

from sabnzbd_test import api, wait_for


def main() -> None:
    fixtures = Path(sys.argv[1])
    started = time.monotonic()
    added = api("addlocalfile", name=str(fixtures / "fast-connect.nzb"), pp=0)
    assert added["status"], added
    job_id = added["nzo_ids"][0]

    def completed():
        snapshot = api("history", nzo_ids=job_id)["history"]
        current = next(iter(snapshot["slots"]), None)
        if current and current["status"] == "Failed":
            raise AssertionError(f"The healthy NNTP download failed: {current}")
        if current and current["status"] == "Completed" and snapshot["ppslots"] == 0:
            return current
        return None

    # The server timeout is 60 seconds. Finishing within ten seconds proves
    # that the initial connection progressed without timeout recovery.
    finished = wait_for(completed, "the fast NNTP download to complete", timeout=10)
    downloaded = Path(finished["storage"])
    if downloaded.is_dir():
        downloaded /= "payload.bin"
    assert downloaded.read_bytes() == (fixtures / "payload.bin").read_bytes()
    print(f"Fast NNTP download completed intact in {time.monotonic() - started:.2f}s", flush=True)


if __name__ == "__main__":
    main()
