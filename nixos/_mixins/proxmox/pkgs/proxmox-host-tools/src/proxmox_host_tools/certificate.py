from __future__ import annotations

import argparse
import os
import shutil
import sys
import time
from collections.abc import Callable, Sequence
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO


class Error(RuntimeError):
    pass


@dataclass(frozen=True)
class Pmxcfs:
    attempts: int = 60
    interval_seconds: float = 1.0
    sleep: Callable[[float], None] = time.sleep

    def wait_writable(self, destination: Path, stderr: TextIO) -> None:
        probe = destination.with_name(f"{destination.name}.probe.{os.getpid()}")
        try:
            for attempt in range(self.attempts):
                try:
                    probe.touch()
                    probe.unlink()
                    return
                except OSError:
                    if attempt == 0:
                        print(
                            "waiting for writable Proxmox cluster filesystem "
                            f"before installing {destination}",
                            file=stderr,
                        )
                    if attempt + 1 < self.attempts:
                        self.sleep(self.interval_seconds)
            raise Error(
                "timed out waiting for writable Proxmox cluster filesystem "
                f"before installing {destination}"
            )
        finally:
            with suppress(OSError):
                probe.unlink()

    def copy(self, source: Path, destination: Path, stderr: TextIO) -> None:
        self.wait_writable(destination, stderr)
        temporary = destination.with_name(f"{destination.name}.tmp.{os.getpid()}")
        try:
            with source.open("rb") as source_file, temporary.open("wb") as destination_file:
                shutil.copyfileobj(source_file, destination_file)
            os.replace(temporary, destination)
        except OSError as error:
            raise Error(f"failed to install {source} as {destination}") from error
        finally:
            with suppress(OSError):
                temporary.unlink()


def install_certificates(
    pmxcfs: Pmxcfs,
    certificate_source: Path,
    certificate_destination: Path,
    key_source: Path,
    key_destination: Path,
    stderr: TextIO,
) -> None:
    # pmxcfs assigns root:www-data ownership itself and rejects chmod/chown.
    pmxcfs.copy(certificate_source, certificate_destination, stderr)
    pmxcfs.copy(key_source, key_destination, stderr)


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(
        description="Install the Proxmox VE API certificate into pmxcfs"
    )
    argument_parser.add_argument("--certificate-source", type=Path, required=True)
    argument_parser.add_argument("--certificate-destination", type=Path, required=True)
    argument_parser.add_argument("--key-source", type=Path, required=True)
    argument_parser.add_argument("--key-destination", type=Path, required=True)
    argument_parser.add_argument("--attempts", type=positive_integer, default=60)
    argument_parser.add_argument("--interval-seconds", type=float, default=1.0)
    return argument_parser


def run(arguments: Sequence[str], stderr: TextIO) -> int:
    options = parser().parse_args(arguments)
    try:
        install_certificates(
            Pmxcfs(options.attempts, options.interval_seconds),
            options.certificate_source,
            options.certificate_destination,
            options.key_source,
            options.key_destination,
            stderr,
        )
    except Error as error:
        print(f"proxmox-install-api-certificate: {error}", file=stderr)
        return 1
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], sys.stderr))
