from __future__ import annotations

import io
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import pytest

from romm_tools.setup import (
    Error,
    SetupConfig,
    SetupRuntime,
    SetupTask,
    load_config,
    load_environment,
    run,
    run_setup,
    setup_environment,
)


def config_data(tmp_path: Path) -> dict[str, object]:
    return {
        "image": "docker.io/rommapp/romm:test",
        "environment": {
            "DB_HOST": "localhost",
            "DB_QUERY_JSON": '{"unix_socket":"/run/mysqld/mysqld.sock"}',
        },
        "mounts": [
            {
                "source": str(tmp_path / "library"),
                "target": "/romm",
                "read_only": False,
            },
            {
                "source": str(tmp_path / "mysql"),
                "target": "/run/mysqld",
                "read_only": True,
            },
        ],
    }


def write_config(tmp_path: Path) -> Path:
    path = tmp_path / "setup.json"
    path.write_text(json.dumps(config_data(tmp_path)))
    return path


@dataclass
class StatefulRuntime(SetupRuntime):
    database_revision: str = "previous"
    initialized: bool = False

    def run_task(
        self,
        task: SetupTask,
        config: SetupConfig,
        environment: Mapping[str, str],
        output: BinaryIO,
    ) -> None:
        assert config.image.endswith(":test")
        assert environment["DB_PASSWD"] == "quote'$"
        if task is SetupTask.MIGRATE:
            self.database_revision = "head"
            output.write(b"migrated\n")
            return
        if self.database_revision != "head":
            raise Error("startup ran before the migration")
        self.initialized = True
        output.write(b"initialized\n")


class FailingMigrationRuntime(StatefulRuntime):
    def run_task(
        self,
        task: SetupTask,
        config: SetupConfig,
        environment: Mapping[str, str],
        output: BinaryIO,
    ) -> None:
        if task is SetupTask.MIGRATE:
            raise Error("migration failed")
        super().run_task(task, config, environment, output)


def test_loads_typed_config_and_dotenv_without_losing_values(tmp_path: Path) -> None:
    environment_file = tmp_path / "romm.env"
    environment_file.write_text("DB_PASSWD=quote'$\nOIDC_CLIENT_SECRET='space value'\n")

    config = load_config(write_config(tmp_path))
    secrets = load_environment(environment_file)
    environment = setup_environment(config, secrets)

    assert environment["DB_QUERY_JSON"] == '{"unix_socket":"/run/mysqld/mysqld.sock"}'
    assert environment["DB_PASSWD"] == "quote'$"
    assert environment["OIDC_CLIENT_SECRET"] == "space value"
    assert config.mounts[0].source == tmp_path / "library"


def test_migrates_before_running_startup_initialization(tmp_path: Path) -> None:
    runtime = StatefulRuntime()
    config = load_config(write_config(tmp_path))
    output = io.BytesIO()

    run_setup(runtime, config, {"DB_PASSWD": "quote'$"}, output)

    assert runtime.database_revision == "head"
    assert runtime.initialized
    assert output.getvalue() == b"migrated\ninitialized\n"


def test_migration_failure_never_runs_startup(tmp_path: Path) -> None:
    runtime = FailingMigrationRuntime()
    config = load_config(write_config(tmp_path))

    with pytest.raises(Error, match="migration failed"):
        run_setup(runtime, config, {"DB_PASSWD": "quote'$"}, io.BytesIO())

    assert runtime.database_revision == "previous"
    assert not runtime.initialized


def test_rejects_secret_override_of_public_configuration(tmp_path: Path) -> None:
    config = load_config(write_config(tmp_path))

    with pytest.raises(Error, match="DB_HOST"):
        setup_environment(config, {"DB_HOST": "elsewhere"})


@pytest.mark.parametrize(
    ("field", "value"),
    [("source", "relative"), ("target", "relative")],
)
def test_rejects_relative_mount_paths(tmp_path: Path, field: str, value: str) -> None:
    data = config_data(tmp_path)
    mounts = data["mounts"]
    assert isinstance(mounts, list)
    mount = mounts[0]
    assert isinstance(mount, dict)
    mount[field] = value
    path = tmp_path / "invalid-mount.json"
    path.write_text(json.dumps(data))

    with pytest.raises(Error, match="failed to load"):
        load_config(path)


def test_rejects_dotenv_keys_without_values(tmp_path: Path) -> None:
    path = tmp_path / "invalid.env"
    path.write_text("DB_PASSWD\n")

    with pytest.raises(Error, match="failed to load"):
        load_environment(path)


def test_invalid_config_fails_before_contacting_podman(tmp_path: Path) -> None:
    config = config_data(tmp_path)
    config["unexpected"] = True
    config_path = tmp_path / "invalid.json"
    config_path.write_text(json.dumps(config))
    environment_file = tmp_path / "romm.env"
    environment_file.write_text("DB_PASSWD=secret\n")
    stderr = io.StringIO()

    status = run(
        [
            "--socket-url",
            f"http+unix://{tmp_path}/missing.sock",
            "--config",
            str(config_path),
            "--environment-file",
            str(environment_file),
        ],
        io.BytesIO(),
        stderr,
    )

    assert status == 1
    assert "failed to load" in stderr.getvalue()


def test_unavailable_podman_socket_reports_clean_error(tmp_path: Path) -> None:
    environment_file = tmp_path / "romm.env"
    environment_file.write_text("DB_PASSWD=secret\n")
    stderr = io.StringIO()

    status = run(
        [
            "--socket-url",
            f"http+unix://{tmp_path}/missing.sock",
            "--config",
            str(write_config(tmp_path)),
            "--environment-file",
            str(environment_file),
        ],
        io.BytesIO(),
        stderr,
    )

    assert status == 1
    assert "failed to run RomM database migration" in stderr.getvalue()
