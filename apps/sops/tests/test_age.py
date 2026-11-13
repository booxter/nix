from __future__ import annotations

from pathlib import Path

import pytest
from sops_tools.age import AgeRecipientResolver
from sops_tools.errors import ToolError

from .fakes import RecordingRunner


def identity(tmp_path: Path, content: str) -> Path:
    path = tmp_path / "identity.txt"
    path.write_text(content)
    return path


def test_native_identity_uses_age_keygen(tmp_path: Path) -> None:
    runner = RecordingRunner(outputs=["age1native1test\n"])
    path = identity(tmp_path, "# native\nAGE-SECRET-KEY-1TEST\n")

    assert AgeRecipientResolver(runner).derive(path) == ["age1native1test"]


def test_secure_enclave_prefers_recipient_metadata(tmp_path: Path) -> None:
    runner = RecordingRunner()
    path = identity(
        tmp_path,
        "# public key: age1se1metadata\nAGE-PLUGIN-SE-1TEST\n",
    )

    assert AgeRecipientResolver(runner).derive(path) == ["age1se1metadata"]


def test_secure_enclave_can_derive_missing_metadata(tmp_path: Path) -> None:
    runner = RecordingRunner(outputs=["age1se1derived\n"])
    path = identity(tmp_path, "AGE-PLUGIN-SE-1TEST\n")

    assert AgeRecipientResolver(runner).derive(path) == ["age1se1derived"]


@pytest.mark.parametrize(
    "content",
    [
        "AGE-PLUGIN-YUBIKEY-1TEST\n",
        "# Recipient: age1yubikey1one\n# Recipient: age1yubikey1two\nAGE-PLUGIN-YUBIKEY-1TEST\n",
    ],
)
def test_yubikey_requires_one_metadata_recipient(tmp_path: Path, content: str) -> None:
    with pytest.raises(ToolError, match="one recipient metadata line per identity"):
        AgeRecipientResolver(RecordingRunner()).derive(identity(tmp_path, content))


def test_yubikey_uses_its_paired_metadata_recipient(tmp_path: Path) -> None:
    path = identity(
        tmp_path,
        "# Recipient: age1yubikey1test\nAGE-PLUGIN-YUBIKEY-1TEST\n",
    )

    assert AgeRecipientResolver(RecordingRunner()).derive(path) == ["age1yubikey1test"]


def test_yubikey_file_includes_each_recipient_in_order(tmp_path: Path) -> None:
    path = identity(
        tmp_path,
        "# Recipient: age1yubikey1main\nAGE-PLUGIN-YUBIKEY-1MAIN\n"
        "# Recipient: age1yubikey1laptop\nAGE-PLUGIN-YUBIKEY-1LAPTOP\n",
    )

    assert AgeRecipientResolver(RecordingRunner()).derive(path) == [
        "age1yubikey1main",
        "age1yubikey1laptop",
    ]


def test_yubikey_file_rejects_mixed_identity_types(tmp_path: Path) -> None:
    path = identity(
        tmp_path,
        "# Recipient: age1yubikey1main\nAGE-PLUGIN-YUBIKEY-1MAIN\nAGE-PLUGIN-SE-1TEST\n",
    )

    with pytest.raises(ToolError, match="Mixed identity types"):
        AgeRecipientResolver(RecordingRunner()).derive(path)


def test_unknown_identity_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(ToolError, match="Unsupported age identity type"):
        AgeRecipientResolver(RecordingRunner()).derive(
            identity(tmp_path, "AGE-PLUGIN-UNKNOWN-1TEST\n")
        )
