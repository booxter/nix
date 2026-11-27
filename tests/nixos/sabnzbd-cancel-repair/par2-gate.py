"""Hold a real PAR2 verification at a deterministic cancellation point."""

import os
import subprocess
import sys
import time
from pathlib import Path


def main() -> None:
    command = sys.argv[1:]
    if len(command) < 2 or command[1] != "r":
        os.execv(command[0], command)

    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            if line.startswith(b"Verifying source files:"):
                # Only the worker's output is delayed. SABnzbd, its API, the
                # downloaded data, and PAR2 itself are otherwise unmodified.
                Path(f"/run/sabnzbd-par2-gate/{os.getpid()}").touch()
                while True:
                    time.sleep(0.1)

        sys.exit(process.wait())


if __name__ == "__main__":
    main()
