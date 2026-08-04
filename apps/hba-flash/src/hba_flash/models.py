from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class FlashOptions:
    host: str = "beast"
    controller: str = "0"
    bundle: Path | None = None
    sas3flash_bundle: Path | None = None
    firmware_bundle: Path | None = None
    sas3flash: Path | None = None
    firmware: Path | None = None
    optionrom: Path | None = None
    flash: bool = False
    quiesce: bool = True
    reboot: bool = False
    keep_remote: bool = False


@dataclass(frozen=True)
class BundleDefaults:
    sas3flash: Path | None = None
    firmware: Path | None = None


@dataclass(frozen=True)
class Artifacts:
    sas3flash: Path
    firmware: Path
    optionrom: Path | None
