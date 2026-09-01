from __future__ import annotations

import json
from pathlib import Path

import pytest
from sops_tools.errors import ToolError
from sops_tools.repository import Realm, RuntimeEnvironment, SecretRepository

from .fakes import FailingRunner, RecordingRunner


def runtime(
    tmp_path: Path,
    *,
    system: str = "Linux",
    extra: dict[str, str] | None = None,
) -> RuntimeEnvironment:
    values = {"HOME": str(tmp_path / "home"), **(extra or {})}
    return RuntimeEnvironment.discover(
        RecordingRunner(outputs=[str(tmp_path)]),
        values=values,
        cwd=tmp_path,
        system_name=system,
        hostname="controller",
    )


def test_explicit_home_realm_does_not_require_inventory(tmp_path: Path) -> None:
    assert runtime(tmp_path).resolve_realm("home") == Realm("home", None)


def test_repository_falls_back_to_packaged_root_outside_git(tmp_path: Path) -> None:
    packaged_root = tmp_path / "packaged"

    environment = RuntimeEnvironment.discover(
        FailingRunner("not a git checkout"),
        values={"SOPS_TOOLS_REPO_ROOT": str(packaged_root)},
        cwd=tmp_path,
        system_name="Linux",
        hostname="controller",
    )

    assert environment.repo_root == packaged_root


def test_default_realm_comes_from_inventory(tmp_path: Path) -> None:
    inventory = tmp_path / "realms.json"
    inventory.write_text(json.dumps({"controller": "home"}))

    realm = runtime(tmp_path, extra={"SOPS_REALMS_FILE": str(inventory)}).resolve_realm(None)

    assert realm == Realm("home", None)


def test_darwin_realm_identity_uses_application_support(tmp_path: Path) -> None:
    identity = tmp_path / "home/Library/Application Support/sops/age/work.txt"
    identity.parent.mkdir(parents=True)
    identity.touch()

    realm = runtime(tmp_path, system="Darwin").resolve_realm("work")

    assert realm.identity_file == identity


def test_linux_realm_identity_uses_xdg_config_home(tmp_path: Path) -> None:
    identity = tmp_path / "xdg/sops/age/work.txt"
    identity.parent.mkdir(parents=True)
    identity.touch()

    realm = runtime(
        tmp_path,
        extra={"XDG_CONFIG_HOME": str(tmp_path / "xdg")},
    ).resolve_realm("work")

    assert realm.identity_file == identity


def test_missing_realm_identity_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(ToolError, match="Age identity for realm 'work'"):
        runtime(tmp_path).resolve_realm("work")


def test_host_must_belong_to_bootstrap_realm(tmp_path: Path) -> None:
    inventory = tmp_path / "realms.json"
    inventory.write_text(json.dumps({"newhost": "home"}))
    environment = runtime(tmp_path, extra={"SOPS_REALMS_FILE": str(inventory)})

    with pytest.raises(ToolError, match="belongs to realm 'home', not 'work'"):
        environment.assert_realm_host(Realm("work", None), "newhost")


def test_repository_reports_missing_secret_role(tmp_path: Path) -> None:
    repository = SecretRepository(tmp_path, Realm("home", None))

    with pytest.raises(ToolError, match="Destination secret not found"):
        repository.require_secret("missing", role="Destination")
