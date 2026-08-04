from __future__ import annotations

import os
from pathlib import Path

import pytest
from ruamel.yaml.parser import ParserError

from bazarr_auth_config.cli import run
from bazarr_auth_config.configuration import ConfigurationError, load_configuration, yaml_codec


def test_reconcile_preserves_unmanaged_yaml_and_comments(tmp_path: Path) -> None:
    path = tmp_path / "config" / "config.yaml"
    path.parent.mkdir()
    path.write_text(
        "# keep this comment\n"
        "general:\n"
        "  port: 6767\n"
        "auth:\n"
        "  type: form\n"
        "  username: admin\n"
        "  password: secret\n",
        encoding="utf-8",
    )

    run(
        [
            "--config",
            str(path),
            "--uid",
            str(os.getuid()),
            "--gid",
            str(os.getgid()),
        ]
    )

    rendered = path.read_text(encoding="utf-8")
    assert "# keep this comment" in rendered
    configuration = load_configuration(path, yaml_codec())
    assert configuration["general"] == {"port": 6767}
    assert configuration["auth"] == {"type": None, "username": "", "password": ""}
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700
    assert path.stat().st_uid == os.getuid()
    assert path.stat().st_gid == os.getgid()


@pytest.mark.parametrize("existing", [None, "", "auth: disabled\n"])
def test_reconcile_creates_auth_mapping(tmp_path: Path, existing: str | None) -> None:
    path = tmp_path / "config" / "config.yaml"
    if existing is not None:
        path.parent.mkdir()
        path.write_text(existing, encoding="utf-8")

    run(
        [
            "--config",
            str(path),
            "--uid",
            str(os.getuid()),
            "--gid",
            str(os.getgid()),
        ]
    )

    configuration = load_configuration(path, yaml_codec())
    assert configuration["auth"] == {"type": None, "username": "", "password": ""}


@pytest.mark.parametrize(
    ("content", "error"),
    [
        ("- list\n", ConfigurationError),
        ("unclosed: [\n", ParserError),
    ],
)
def test_invalid_configuration_is_not_replaced(
    tmp_path: Path,
    content: str,
    error: type[Exception],
) -> None:
    path = tmp_path / "config" / "config.yaml"
    path.parent.mkdir()
    path.write_text(content, encoding="utf-8")

    with pytest.raises(error):
        run(
            [
                "--config",
                str(path),
                "--uid",
                str(os.getuid()),
                "--gid",
                str(os.getgid()),
            ]
        )

    assert path.read_text(encoding="utf-8") == content
