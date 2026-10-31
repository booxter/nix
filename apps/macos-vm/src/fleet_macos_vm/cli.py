from __future__ import annotations

import argparse
import os
import platform
import signal
import sys
from pathlib import Path
from threading import Event
from types import FrameType

from fleet_macos_vm.process import Cancelled, Commands
from fleet_macos_vm.state import Bootstrap, Image, State, run_vm
from fleet_macos_vm.tart import Tart, check_host


def execute(checkout: Path, *, gui: bool, reset: bool) -> int:
    os.umask(0o077)
    cancelled = Event()

    def request_shutdown(_number: int, _frame: FrameType | None) -> None:
        cancelled.set()

    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, request_shutdown)

    state_home = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    root = state_home.resolve() / "fleet-vm" / "macos"
    environment = dict(os.environ)
    environment.update(
        {
            "TART_HOME": str(root / "tart"),
            "TART_NO_AUTO_PRUNE": "1",
            "SSH_ASKPASS_REQUIRE": "never",
        }
    )
    commands = Commands(environment, cancelled)
    check_host(platform.system(), platform.machine(), platform.mac_ver()[0])
    image = Image.model_validate_json(Path(os.environ["FLEET_VM_IMAGE"]).read_text())
    bootstrap = Bootstrap.model_validate_json(Path(os.environ["FLEET_VM_BOOTSTRAP"]).read_text())
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    return run_vm(
        State(root, checkout), Tart(root, commands), image, bootstrap, gui=gui, reset=reset
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Internal macOS backend for nix run .#vm")
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--gui", action="store_true")
    parser.add_argument("--reset", action="store_true")
    arguments = parser.parse_args()
    try:
        return execute(arguments.checkout, gui=arguments.gui, reset=arguments.reset)
    except Cancelled:
        print("VM preparation interrupted; retry with the same command.", file=sys.stderr)
        return 130
    except (OSError, RuntimeError, ValueError) as error:
        print(f"vm: {error}", file=sys.stderr)
        return 1
