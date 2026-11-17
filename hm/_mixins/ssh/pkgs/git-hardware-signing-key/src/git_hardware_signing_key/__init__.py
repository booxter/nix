import argparse
import os
import pathlib
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class PublicKey:
    algorithm: str
    material: str

    @classmethod
    def parse(cls, text: str) -> "PublicKey":
        fields = text.split()
        if len(fields) < 2 or len(text.strip().splitlines()) != 1:
            raise ValueError("Expected one SSH public key")
        # Comments identify people or devices but are not part of the key.
        return cls(fields[0], fields[1])

    def git_value(self) -> str:
        return f"key::{self.algorithm} {self.material}"


class Commands(Protocol):
    def output(self, arguments: Sequence[str]) -> str: ...


class SystemCommands:
    def output(self, arguments: Sequence[str]) -> str:
        return subprocess.run(arguments, check=True, text=True, stdout=subprocess.PIPE).stdout


def select_key(
    approved: set[PublicKey],
    commands: Commands,
    local_command: str | None,
    forwarded: bool,
) -> PublicKey:
    selected = None
    # Forwarded sessions must never load the destination machine's identities.
    if local_command is not None and not forwarded:
        selected = PublicKey.parse(commands.output([local_command]))

    for line in commands.output(["ssh-add", "-L"]).splitlines():
        key = PublicKey.parse(line)
        if key in approved and (selected is None or key == selected):
            return key

    raise ValueError("No approved hardware signing key is available in the SSH agent.")


def run(argv: Sequence[str], commands: Commands, *, forwarded: bool) -> int:
    parser = argparse.ArgumentParser(description="Choose an approved Git SSH signing key")
    parser.add_argument("--approved-keys", required=True, type=pathlib.Path)
    parser.add_argument("--local-identity-command")
    args = parser.parse_args(argv)

    try:
        approved = {
            PublicKey.parse(line)
            for line in args.approved_keys.read_text().splitlines()
            if line.strip()
        }
        key = select_key(approved, commands, args.local_identity_command, forwarded)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"git-hardware-signing-key: {error}", file=sys.stderr)
        return 1

    print(key.git_value())
    return 0


def main() -> int:
    return run(sys.argv[1:], SystemCommands(), forwarded=bool(os.environ.get("SSH_CONNECTION")))
