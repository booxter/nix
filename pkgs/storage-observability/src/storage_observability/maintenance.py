"""Skip unattended maintenance while an MD reshape is unfinished."""

from pathlib import Path
from typing import TextIO


def guard_raid(sys_block: Path, stderr: TextIO) -> int:
    for device in sorted(sys_block.iterdir()):
        md = device / "md"
        if not md.is_dir():
            continue

        state = (md / "array_state").read_text().strip()
        # An inactive assembly has not loaded its members' reshape metadata yet.
        if state in {"inactive", "clear"}:
            print(f"Skipping maintenance: {device.name} is {state}.", file=stderr)
            return 1

        position = (md / "reshape_position").read_text().strip()
        if position == "none":
            continue
        if not position.isascii() or not position.isdecimal():
            raise ValueError(f"{device.name}: invalid reshape position {position!r}")

        # sync_action can be idle or frozen while the reshape is still pending.
        print(f"Skipping maintenance: {device.name} has an unfinished reshape.", file=stderr)
        return 1

    return 0
