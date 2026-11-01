from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Protocol, TextIO

from atomic_file_writes import write_bytes_atomic
from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

IDENTITY_DIRECTORY = Path("/run/bootstrap")
IDENTITY_PATH = IDENTITY_DIRECTORY / "ssh_host_ed25519_key"
PUBLIC_KEY_PATH = Path("/etc/proxmox-bootstrap/host.pub")
RECEIVER = "/run/current-system/sw/bin/proxmox-install-identity"


class IdentityError(ValueError):
    """An installation identity is invalid or belongs to another host."""


def validate_identity(private_key: bytes, public_key: str) -> None:
    try:
        private = serialization.load_ssh_private_key(private_key, password=None)
        expected = serialization.load_ssh_public_key(public_key.encode())
    except (ValueError, TypeError, UnsupportedAlgorithm) as error:
        raise IdentityError("expected an unencrypted Ed25519 SSH host key") from error

    if not isinstance(private, Ed25519PrivateKey) or not isinstance(expected, Ed25519PublicKey):
        raise IdentityError("installation identities must use Ed25519")

    actual = private.public_key().public_bytes_raw()
    if actual != expected.public_bytes_raw():
        raise IdentityError("installation identity does not match the expected public key")


class IdentityStore(Protocol):
    def public_key(self) -> str: ...

    def publish(self, private_key: bytes) -> None: ...


@dataclass(frozen=True)
class FileIdentityStore:
    public_key_path: Path = PUBLIC_KEY_PATH
    identity_path: Path = IDENTITY_PATH

    def public_key(self) -> str:
        return self.public_key_path.read_text()

    def publish(self, private_key: bytes) -> None:
        self.identity_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.identity_path.parent.chmod(0o700)
        write_bytes_atomic(self.identity_path, private_key, mode=0o600)


def receive_identity(private_key: bytes, store: IdentityStore) -> None:
    validate_identity(private_key, store.public_key())
    store.publish(private_key)


def entrypoint(
    arguments: Sequence[str] | None = None,
    *,
    stdin: BinaryIO | None = None,
    stderr: TextIO | None = None,
    store: IdentityStore | None = None,
) -> int:
    parser = argparse.ArgumentParser(
        description="Receive the expected SSH host identity over stdin"
    )
    parser.parse_args(arguments)
    source = sys.stdin.buffer if stdin is None else stdin
    errors = sys.stderr if stderr is None else stderr
    destination = FileIdentityStore() if store is None else store
    try:
        receive_identity(source.read(), destination)
    except (IdentityError, OSError) as error:
        print(f"proxmox-install-identity: {error}", file=errors)
        return 1
    return 0
