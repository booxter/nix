"""Make one healthy article for the fast-connection regression."""

import hashlib
import sys
from pathlib import Path

from sabnzbd_test import make_nzb


def main() -> None:
    directory = Path(sys.argv[1])
    directory.mkdir()
    (directory / "payload.bin").write_bytes(hashlib.shake_256(b"fast-connect").digest(64 * 1024))
    make_nzb(directory, "fast-connect")


if __name__ == "__main__":
    main()
