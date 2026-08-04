from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

SYSTEM_LINKS = ("initrd", "kernel", "kernel-modules")
REBOOT_MESSAGE = "Rebooting to activate staged NixOS kernel, initrd, or module upgrade"


def system_link_targets(profile: Path) -> tuple[str, ...]:
    return tuple(os.readlink(profile / name) for name in SYSTEM_LINKS)


def reboot_required(booted_system: Path, current_system: Path) -> bool:
    return system_link_targets(booted_system) != system_link_targets(current_system)


class RebootScheduler(Protocol):
    def schedule(self, message: str) -> None: ...


@dataclass(frozen=True)
class ShutdownCommand:
    executable: Path

    def schedule(self, message: str) -> None:
        subprocess.run(
            [self.executable, "-r", "+1", message],
            check=True,
        )


def schedule_reboot_if_needed(
    scheduler: RebootScheduler,
    *,
    booted_system: Path = Path("/run/booted-system"),
    current_system: Path = Path("/nix/var/nix/profiles/system"),
) -> bool:
    if not reboot_required(booted_system, current_system):
        return False
    scheduler.schedule(REBOOT_MESSAGE)
    return True
