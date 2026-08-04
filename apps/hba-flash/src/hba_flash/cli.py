from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

from .models import BundleDefaults, FlashOptions
from .process import FlashError, SubprocessRunner
from .remote import OpenSshRemoteHba
from .workflow import HbaFlashWorkflow


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="hba-flash",
        description=(
            "Preflight and flash the Broadcom/LSI HBA on beast. The default "
            "mode is read-only preflight."
        ),
    )
    command.add_argument("--host", default="beast", help="SSH target (default: beast)")
    command.add_argument("--controller", default="0", help="sas3flash controller index")
    command.add_argument("--bundle", type=Path, help="directory or ZIP containing both inputs")
    command.add_argument("--sas3flash-bundle", type=Path, help="utility bundle directory or ZIP")
    command.add_argument("--firmware-bundle", type=Path, help="firmware bundle directory or ZIP")
    command.add_argument("--sas3flash", type=Path, help="Linux sas3flash utility")
    command.add_argument("--firmware", type=Path, help="HBA firmware image")
    command.add_argument("--optionrom", type=Path, help="optional BIOS/UEFI option ROM")
    command.add_argument("--flash", action="store_true", help="perform the firmware flash")
    command.add_argument(
        "--no-quiesce",
        action="store_true",
        help="skip service stop, unmount, and md stop",
    )
    command.add_argument("--reboot", action="store_true", help="reboot after a successful flash")
    command.add_argument("--keep-remote", action="store_true", help="keep staged remote files")
    return command


def _optional_path(environment: Mapping[str, str], name: str) -> Path | None:
    value = environment.get(name)
    return Path(value) if value else None


def defaults(environment: Mapping[str, str]) -> BundleDefaults:
    return BundleDefaults(
        sas3flash=_optional_path(environment, "HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE"),
        firmware=_optional_path(environment, "HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE"),
    )


def options(namespace: argparse.Namespace) -> FlashOptions:
    return FlashOptions(
        host=namespace.host,
        controller=namespace.controller,
        bundle=namespace.bundle,
        sas3flash_bundle=namespace.sas3flash_bundle,
        firmware_bundle=namespace.firmware_bundle,
        sas3flash=namespace.sas3flash,
        firmware=namespace.firmware,
        optionrom=namespace.optionrom,
        flash=namespace.flash,
        quiesce=not namespace.no_quiesce,
        reboot=namespace.reboot,
        keep_remote=namespace.keep_remote,
    )


def main(argv: Sequence[str] | None = None) -> int:
    namespace = parser().parse_args(argv if argv is not None else sys.argv[1:])
    runner = SubprocessRunner()
    workflow = HbaFlashWorkflow(lambda host: OpenSshRemoteHba(host, runner), sys.stderr)
    try:
        workflow.execute(options(namespace), defaults(os.environ))
    except FlashError as error:
        workflow.note(f"error: {error}")
        return 1
    return 0
