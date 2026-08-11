from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

import pytest

from restic_tools.models import OffloadConfig
from restic_tools.offload import OffloadFailure, offload, prune
from restic_tools.offload_cli import parser, run
from restic_tools.prune_cli import parser as prune_parser
from restic_tools.prune_cli import run as run_prune


@dataclass
class StatefulRestic:
    exists: bool
    fail_copy: bool = False
    initialized: bool = False
    copied: bool = False
    forgotten: bool = False
    pruned: bool = False
    unlocks: int = 0

    def destination_exists(self) -> bool:
        return self.exists

    def initialize(self) -> None:
        self.initialized = True
        self.exists = True

    def unlock(self) -> None:
        self.unlocks += 1

    def copy(self) -> None:
        if self.fail_copy:
            raise OffloadFailure("copy", 17)
        self.copied = True

    def forget(self) -> None:
        self.forgotten = True

    def prune(self) -> None:
        self.pruned = True


def config(tmp_path: Path) -> OffloadConfig:
    key_id = tmp_path / "key-id"
    key = tmp_path / "key"
    key_id.write_text(" application-id\n", encoding="utf-8")
    key.write_text(" application-key\n", encoding="utf-8")
    return OffloadConfig(
        backend="b2",
        sourceRepository=tmp_path / "source",
        sourcePasswordFile=tmp_path / "source-password",
        destinationRepository="b2:backups:hosts/beast",
        destinationPasswordFile=tmp_path / "destination-password",
        applicationKeyIdFile=key_id,
        applicationKeyFile=key,
        backendConnections=1,
        packSizeMib=4,
        pruneOptions=("--keep-daily=14",),
    )


def test_missing_destination_is_initialized_and_offloaded() -> None:
    restic = StatefulRestic(exists=False)

    offload(restic)

    assert restic.initialized
    assert restic.copied
    assert not restic.pruned
    assert restic.unlocks == 1


def test_failed_copy_unlocks_and_does_not_prune() -> None:
    restic = StatefulRestic(exists=True, fail_copy=True)

    with pytest.raises(OffloadFailure) as raised:
        offload(restic)

    assert raised.value.exit_code == 17
    assert restic.unlocks == 2
    assert not restic.pruned


def test_prune_unlocks_and_prunes_destination() -> None:
    restic = StatefulRestic(exists=True)

    prune(restic)

    assert restic.forgotten
    assert restic.pruned
    assert restic.unlocks == 1


@dataclass
class RecordingFactory:
    client: StatefulRestic
    environment: Mapping[str, str] | None = None

    def __call__(
        self,
        _config: OffloadConfig,
        environment: Mapping[str, str],
    ) -> StatefulRestic:
        self.environment = environment
        return self.client


def test_cli_loads_config_and_credentials(tmp_path: Path) -> None:
    offload_config = config(tmp_path)
    config_path = tmp_path / "config.json"
    config_path.write_text(
        offload_config.model_dump_json(by_alias=True),
        encoding="utf-8",
    )
    arguments = parser().parse_args(["--config", str(config_path)])
    client = StatefulRestic(exists=True)
    factory = RecordingFactory(client)

    assert run(arguments, factory) == 0
    assert factory.environment is not None
    assert factory.environment["B2_ACCOUNT_ID"] == "application-id"
    assert factory.environment["B2_ACCOUNT_KEY"] == "application-key"
    assert factory.environment["AWS_ACCESS_KEY_ID"] == "application-id"
    assert factory.environment["AWS_SECRET_ACCESS_KEY"] == "application-key"
    assert client.copied


def test_prune_cli_loads_config_and_credentials(tmp_path: Path) -> None:
    offload_config = config(tmp_path)
    config_path = tmp_path / "config.json"
    config_path.write_text(
        offload_config.model_dump_json(by_alias=True),
        encoding="utf-8",
    )
    arguments = prune_parser().parse_args(["--config", str(config_path)])
    client = StatefulRestic(exists=True)
    factory = RecordingFactory(client)

    assert run_prune(arguments, factory) == 0
    assert client.pruned


def test_cli_supports_destination_without_b2_credentials(tmp_path: Path) -> None:
    offload_config = config(tmp_path).model_copy(
        update={
            "backend": "local",
            "destination_repository": str(tmp_path / "destination"),
            "application_key_id_file": None,
            "application_key_file": None,
        }
    )
    config_path = tmp_path / "config.json"
    config_path.write_text(
        offload_config.model_dump_json(by_alias=True),
        encoding="utf-8",
    )
    client = StatefulRestic(exists=True)
    factory = RecordingFactory(client)

    assert run(parser().parse_args(["--config", str(config_path)]), factory) == 0
    assert factory.environment is not None
    assert "B2_ACCOUNT_ID" not in factory.environment
    assert "B2_ACCOUNT_KEY" not in factory.environment
    assert client.copied


def test_cli_rejects_partial_cloud_credentials(tmp_path: Path) -> None:
    offload_config = config(tmp_path).model_copy(update={"application_key_file": None})
    config_path = tmp_path / "config.json"
    config_path.write_text(
        offload_config.model_dump_json(by_alias=True),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="both cloud application key files"):
        run(parser().parse_args(["--config", str(config_path)]))
