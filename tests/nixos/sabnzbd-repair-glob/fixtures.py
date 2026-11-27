"""Make two-set jobs with identical data and different PAR2 set names."""

import hashlib
import subprocess
import sys
from pathlib import Path

from sabnzbd_test import Segment, make_nzb

BLOCK = 16 * 1024


def make_job(directory: Path, episode: str, par2: str) -> None:
    directory.mkdir(parents=True)
    for name, seed in ((episode, b"episode"), ("Other", b"unrelated")):
        payload = directory / f"{name}.bin"
        payload.write_bytes(hashlib.shake_256(seed).digest(4 * BLOCK))
        subprocess.run(
            [par2, "create", "-q", "-t1", f"-s{BLOCK}", "-c1", f"{name}.par2", payload.name],
            cwd=directory,
            check=True,
        )

    # Omit one complete block so PAR2 must scan the episode and can repair it.
    segments = [Segment(i + 1, i * BLOCK, BLOCK) for i in (0, 2, 3)]
    make_nzb(directory, directory.name, {f"{episode}.bin": segments})


if __name__ == "__main__":
    root = Path(sys.argv[1])
    make_job(root / "plain", "Episode1080p", sys.argv[2])
    make_job(root / "bracketed", "Episode[1080p]", sys.argv[2])
