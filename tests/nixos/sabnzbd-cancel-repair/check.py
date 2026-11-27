"""Cancel a multi-set repair through the API, then delete the cancelled job."""

import sys
from pathlib import Path

from sabnzbd_test import api, history, wait_for


def main() -> None:
    added = api("addlocalfile", name=sys.argv[1], pp=1)
    assert added["status"], added
    job_id = added["nzo_ids"][0]
    gate = Path("/run/sabnzbd-par2-gate")
    wait_for(lambda: list(gate.iterdir()), "PAR2 to begin verifying the first set")
    before = history(job_id)
    assert before is not None and before["loaded"], before
    print(f"Cancelling {job_id}: {before['status']}", flush=True)

    cancelled = api("cancel_pp", value=job_id)
    assert cancelled["status"], cancelled

    def finished_or_restarted():
        snapshot = api("history", nzo_ids=job_id)["history"]
        current = next(iter(snapshot["slots"]), None)
        if current and current["status"] == "Failed" and snapshot["ppslots"] == 0:
            return current
        if len(list(gate.iterdir())) > 1:
            raise AssertionError(
                f"SABnzbd acknowledged cancellation, then started another PAR2 set: {current}"
            )
        return None

    finished = wait_for(finished_or_restarted, "the cancelled job to finish", timeout=10)
    assert "aborted" in finished["fail_message"].lower(), finished
    assert not any(slot["nzo_id"] == job_id for slot in api("queue")["queue"]["slots"])

    deleted = api("history", name="delete", value=job_id, del_files=1, archive=0)
    assert deleted["status"], deleted
    wait_for(lambda: history(job_id) is None, "the cancelled job to be deleted")
    assert not Path(before["path"]).exists(), "Deleting the job left its incomplete files behind"
    print("Cancellation finished and the job and its files were deleted", flush=True)


if __name__ == "__main__":
    main()
