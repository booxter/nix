from __future__ import annotations

from pathlib import Path

import pytest

from sops_tools.errors import ToolError
from sops_tools.passwords import (
    CommandPasswordHasher,
    CommandPasswordStore,
    PasswordService,
)
from sops_tools.repository import SecretDomain, SecretRepository

from .fakes import (
    MemoryPasswordStore,
    MemorySopsBackend,
    RecordingRunner,
    StaticPasswordHasher,
)


def service(
    tmp_path: Path,
) -> tuple[PasswordService, MemoryPasswordStore, MemorySopsBackend]:
    repository = SecretRepository(tmp_path, SecretDomain("main", None))
    repository.directory.mkdir(parents=True)
    secret = repository.secret("beast")
    secret.touch()
    backend = MemorySopsBackend(
        {
            secret: {
                "users": {
                    "root": {"hashedPassword": "old-root"},
                    "ihrachyshka": {"hashedPassword": "old-user"},
                },
                "keep": "value",
            }
        }
    )
    store = MemoryPasswordStore()
    return (
        PasswordService(repository, backend, store, StaticPasswordHasher()),
        store,
        backend,
    )


def test_insert_updates_only_the_requested_user(tmp_path: Path) -> None:
    passwords, store, backend = service(tmp_path)

    result = passwords.update("beast", "root", generate=False)

    assert result.action == "Inserted"
    assert store.calls[:2] == [
        ("insert", "host/beast/root"),
        ("read", "host/beast/root"),
    ]
    document = backend.documents[passwords.repository.secret("beast")]
    assert document == {
        "users": {
            "root": {"hashedPassword": "$6$hashed"},
            "ihrachyshka": {"hashedPassword": "old-user"},
        },
        "keep": "value",
    }


def test_generate_honors_prefix_and_length(tmp_path: Path) -> None:
    passwords, store, _ = service(tmp_path)

    result = passwords.update(
        "beast",
        "ihrachyshka",
        generate=True,
        prefix="machines",
        length=47,
    )

    assert result.entries == ("machines/beast/ihrachyshka",)
    assert store.calls[0] == ("generate", "machines/beast/ihrachyshka", 47)


def test_both_users_share_one_password_and_hash(tmp_path: Path) -> None:
    passwords, store, backend = service(tmp_path)

    result = passwords.update("beast", "both", generate=True)

    assert result.entries == ("host/beast/root", "host/beast/ihrachyshka")
    assert store.values["host/beast/root"] == store.values["host/beast/ihrachyshka"]
    document = backend.documents[passwords.repository.secret("beast")]
    assert document["users"] == {
        "root": {"hashedPassword": "$6$hashed"},
        "ihrachyshka": {"hashedPassword": "$6$hashed"},
    }


def test_empty_password_does_not_modify_the_secret(tmp_path: Path) -> None:
    passwords, store, backend = service(tmp_path)
    store.empty_insert = True
    before = backend.decrypt_data(passwords.repository.secret("beast"))

    with pytest.raises(ToolError, match="Stored password must not be empty"):
        passwords.update("beast", "root", generate=False)

    assert backend.decrypt_data(passwords.repository.secret("beast")) == before


def test_missing_secret_fails_before_touching_password_store(tmp_path: Path) -> None:
    passwords, store, _ = service(tmp_path)

    with pytest.raises(ToolError, match="Bootstrap it first"):
        passwords.update("missing", "root", generate=False)

    assert store.calls == []


def test_command_store_reads_only_the_password_line() -> None:
    store = CommandPasswordStore(
        RecordingRunner(outputs=["password\nmetadata ignored\n"])
    )

    assert store.read("host/beast/root") == "password"


def test_command_hasher_requires_sha512_crypt_format() -> None:
    valid = CommandPasswordHasher(RecordingRunner(outputs=["$6$salt$hash\n"]))
    invalid = CommandPasswordHasher(RecordingRunner(outputs=["not-a-hash\n"]))

    assert valid.sha512("password") == "$6$salt$hash"
    with pytest.raises(ToolError, match="unexpected hash format"):
        invalid.sha512("password")
