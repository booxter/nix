"""Make two independently damaged PAR2 sets for SABnzbd's NNTP fixture."""

import hashlib
import subprocess
import sys
from pathlib import Path

from sabnzbd_test import make_nzb


def make_set(directory: Path, name: str, par2: str) -> None:
    data = bytearray(hashlib.shake_256(name.encode()).digest(64 * 1024))
    payload = directory / f"{name}.bin"
    payload.write_bytes(data)
    subprocess.run(
        [par2, "create", "-q", "-t1", "-s4096", "-c1", str(directory / name), str(payload)],
        check=True,
    )

    # Damage two blocks after creating one block of recovery data. The article
    # checksums remain valid, but quick-check cannot skip PAR2 verification.
    data[0] ^= 1
    data[4096] ^= 1
    payload.write_bytes(data)


def main() -> None:
    directory = Path(sys.argv[1])
    directory.mkdir()
    for name in ("first", "second"):
        make_set(directory, name, sys.argv[2])
    make_nzb(directory, "multi-set")


if __name__ == "__main__":
    main()
