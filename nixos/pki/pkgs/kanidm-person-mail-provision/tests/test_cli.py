from __future__ import annotations

import io
import json
import stat
from pathlib import Path

import pytest

from kanidm_person_mail_provision.cli import main


def test_renders_person_mail_addresses(tmp_path: Path) -> None:
    first_mail = tmp_path / "first-mail"
    second_mail = tmp_path / "second-mail"
    output = tmp_path / "persons.json"
    first_mail.write_text("first@example.invalid\n", encoding="utf-8")
    second_mail.write_bytes(b"second+tag@example.invalid\r\n")

    result = main(
        [
            str(output),
            "alpha",
            str(first_mail),
            "beta-user",
            str(second_mail),
        ]
    )

    assert result == 0
    assert json.loads(output.read_text(encoding="utf-8")) == {
        "persons": {
            "alpha": {"mailAddresses": ["first@example.invalid"]},
            "beta-user": {"mailAddresses": ["second+tag@example.invalid"]},
        }
    }
    assert stat.S_IMODE(output.stat().st_mode) == 0o600


def test_rejects_empty_mail_file_without_replacing_output(tmp_path: Path) -> None:
    mail_file = tmp_path / "empty-mail"
    output = tmp_path / "persons.json"
    mail_file.touch()
    output.write_text("existing\n", encoding="utf-8")
    errors = io.StringIO()

    result = main([str(output), "alpha", str(mail_file)], stderr=errors)

    assert result == 1
    assert "mail address file is empty or missing for alpha" in errors.getvalue()
    assert output.read_text(encoding="utf-8") == "existing\n"


def test_rejects_missing_mail_file(tmp_path: Path) -> None:
    mail_file = tmp_path / "missing-mail"
    output = tmp_path / "persons.json"
    errors = io.StringIO()

    result = main([str(output), "alpha", str(mail_file)], stderr=errors)

    assert result == 1
    assert "mail address file is empty or missing for alpha" in errors.getvalue()
    assert not output.exists()


def test_rejects_mail_file_containing_only_newlines(tmp_path: Path) -> None:
    mail_file = tmp_path / "blank-mail"
    output = tmp_path / "persons.json"
    mail_file.write_bytes(b"\r\n\n")
    errors = io.StringIO()

    result = main([str(output), "alpha", str(mail_file)], stderr=errors)

    assert result == 1
    assert "empty mail address for alpha" in errors.getvalue()
    assert not output.exists()


def test_rejects_non_utf8_mail_file(tmp_path: Path) -> None:
    mail_file = tmp_path / "invalid-mail"
    output = tmp_path / "persons.json"
    mail_file.write_bytes(b"\xff\xfe")
    errors = io.StringIO()

    result = main([str(output), "alpha", str(mail_file)], stderr=errors)

    assert result == 1
    assert "failed to read mail address for alpha" in errors.getvalue()
    assert not output.exists()


def test_rejects_missing_output_directory(tmp_path: Path) -> None:
    mail_file = tmp_path / "mail"
    mail_file.write_text("alpha@example.invalid\n", encoding="utf-8")
    output = tmp_path / "missing" / "persons.json"
    errors = io.StringIO()

    result = main([str(output), "alpha", str(mail_file)], stderr=errors)

    assert result == 1
    assert f"output directory does not exist: {output.parent}" in errors.getvalue()


def test_rejects_incomplete_person_mail_pair(tmp_path: Path) -> None:
    with pytest.raises(SystemExit) as raised:
        main([str(tmp_path / "persons.json"), "alpha"])

    assert raised.value.code == 2
