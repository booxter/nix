"""Make multi-set NZBs that need real PAR2 repairs."""

import hashlib
import subprocess
import sys
from pathlib import Path

from sabnzbd_test import Segment, make_nzb

BLOCK = 16 * 1024


def make_set(directory: Path, name: str, seed: bytes, par2: str) -> Path:
    payload = directory / f"{name}.bin"
    payload.write_bytes(hashlib.shake_256(seed).digest(4 * BLOCK))
    subprocess.run(
        [par2, "create", "-q", "-t1", f"-s{BLOCK}", "-c1", f"{name}.par2", payload.name],
        cwd=directory,
        check=True,
    )
    return payload


def make_job(directory: Path, episode: str, par2: str) -> None:
    directory.mkdir(parents=True)
    make_set(directory, episode, b"episode", par2)
    make_set(directory, "Other", b"unrelated", par2)

    # Omit one complete block so PAR2 must scan the episode and can repair it.
    segments = [Segment(i + 1, i * BLOCK, BLOCK) for i in (0, 2, 3)]
    make_nzb(directory, directory.name, {f"{episode}.bin": segments})


def make_shared_prefix_job(directory: Path, par2: str, *, with_spare: bool) -> None:
    directory.mkdir()
    articles = {}
    spare = bytearray()
    for number, name in enumerate(("First", "Second"), 1):
        payload = make_set(directory, name, name.encode(), par2)
        (directory / f"{name}.par2").rename(directory / f"Bundle.vol-{number:02}.par2")
        volume = next(directory.glob(f"{name}.vol*.par2"))
        volume.rename(directory / f"Bundle.vol{number:03}+01.par2")

        blocks = (0, 3) if with_spare else (0, 2, 3)
        articles[payload.name] = [Segment(i + 1, i * BLOCK, BLOCK) for i in blocks]
        if with_spare:
            spare.extend(payload.read_bytes()[BLOCK : 2 * BLOCK])

    if with_spare:
        # Each set needs two blocks. The PAR2 volume supplies one and this
        # unclaimed file contains the other, whichever set is checked first.
        (directory / "spare.bin").write_bytes(spare)
    make_nzb(directory, directory.name, articles)


if __name__ == "__main__":
    root = Path(sys.argv[1])
    make_job(root / "plain", "Episode1080p", sys.argv[2])
    make_job(root / "bracketed", "Episode[1080p]", sys.argv[2])
    make_shared_prefix_job(root / "shared-prefix", sys.argv[2], with_spare=False)
    make_shared_prefix_job(root / "shared-prefix-spare", sys.argv[2], with_spare=True)
