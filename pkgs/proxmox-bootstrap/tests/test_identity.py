from __future__ import annotations

import io
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from proxmox_bootstrap.identity import (
    FileIdentityStore,
    IdentityError,
    entrypoint,
    receive_identity,
    validate_identity,
)


def identity() -> tuple[bytes, str]:
    key = ed25519.Ed25519PrivateKey.generate()
    private = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.NoEncryption(),
    )
    public = key.public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
    )
    return private, public.decode()


def store_for(directory: Path, public: str) -> FileIdentityStore:
    public_path = directory / "host.pub"
    public_path.write_text(public)
    return FileIdentityStore(public_path, directory / "staging" / "host.key")


def test_receiver_publishes_the_matching_identity_with_private_permissions(tmp_path: Path) -> None:
    private, public = identity()
    store = store_for(tmp_path, public + " fixture@example.invalid\n")
    errors = io.StringIO()

    assert entrypoint([], stdin=io.BytesIO(private), stderr=errors, store=store) == 0
    assert store.identity_path.read_bytes() == private
    assert store.identity_path.stat().st_mode & 0o777 == 0o600
    assert store.identity_path.parent.stat().st_mode & 0o777 == 0o700
    assert errors.getvalue() == ""


def test_rejected_identity_cannot_replace_an_accepted_identity(tmp_path: Path) -> None:
    private, public = identity()
    wrong, _ = identity()
    store = store_for(tmp_path, public)
    receive_identity(private, store)

    with pytest.raises(IdentityError, match="does not match"):
        receive_identity(wrong, store)

    assert store.identity_path.read_bytes() == private


def test_invalid_identity_is_rejected_without_publishing_or_printing_it(tmp_path: Path) -> None:
    _, public = identity()
    store = store_for(tmp_path, public)
    errors = io.StringIO()
    invalid = b"private-material-that-must-not-be-logged"

    assert entrypoint([], stdin=io.BytesIO(invalid), stderr=errors, store=store) == 1
    assert "expected an unencrypted Ed25519" in errors.getvalue()
    assert invalid.decode() not in errors.getvalue()
    assert not store.identity_path.exists()


def test_missing_public_key_is_reported_without_publishing(tmp_path: Path) -> None:
    private, _ = identity()
    store = FileIdentityStore(tmp_path / "absent.pub", tmp_path / "host.key")
    errors = io.StringIO()

    assert entrypoint([], stdin=io.BytesIO(private), stderr=errors, store=store) == 1
    assert "absent.pub" in errors.getvalue()
    assert not store.identity_path.exists()


def test_invalid_public_key_is_rejected() -> None:
    private, _ = identity()
    with pytest.raises(IdentityError, match="expected an unencrypted Ed25519"):
        validate_identity(private, "invalid-public-key")


def test_encrypted_host_keys_are_rejected() -> None:
    key = ed25519.Ed25519PrivateKey.generate()
    encrypted = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.BestAvailableEncryption(b"fixture-passphrase"),
    )
    _, public = identity()
    with pytest.raises(IdentityError, match="unencrypted"):
        validate_identity(encrypted, public)


def test_other_key_algorithms_are_rejected() -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.NoEncryption(),
    )
    public = key.public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
    )
    with pytest.raises(IdentityError, match="must use Ed25519"):
        validate_identity(private, public.decode())
