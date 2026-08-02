from __future__ import annotations

import json
from pathlib import Path

import pytest

from sops_tools.errors import ToolError
from sops_tools.repository import RuntimeEnvironment, SecretDomain, SecretRepository

from .fakes import RecordingRunner


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


def test_explicit_main_domain_does_not_require_inventory(tmp_path: Path) -> None:
    assert runtime(tmp_path).resolve_domain("main") == SecretDomain("main", None)


def test_default_domain_comes_from_inventory(tmp_path: Path) -> None:
    inventory = tmp_path / "domains.json"
    inventory.write_text(json.dumps({"controller": "main"}))

    domain = runtime(
        tmp_path, extra={"SOPS_SECRET_DOMAINS_FILE": str(inventory)}
    ).resolve_domain(None)

    assert domain == SecretDomain("main", None)


def test_darwin_domain_identity_uses_application_support(tmp_path: Path) -> None:
    identity = tmp_path / "home/Library/Application Support/sops/age/work.txt"
    identity.parent.mkdir(parents=True)
    identity.touch()

    domain = runtime(tmp_path, system="Darwin").resolve_domain("work")

    assert domain.identity_file == identity


def test_linux_domain_identity_uses_xdg_config_home(tmp_path: Path) -> None:
    identity = tmp_path / "xdg/sops/age/work.txt"
    identity.parent.mkdir(parents=True)
    identity.touch()

    domain = runtime(
        tmp_path,
        extra={"XDG_CONFIG_HOME": str(tmp_path / "xdg")},
    ).resolve_domain("work")

    assert domain.identity_file == identity


def test_missing_domain_identity_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(ToolError, match="Age identity for secret domain 'work'"):
        runtime(tmp_path).resolve_domain("work")


def test_host_must_belong_to_bootstrap_domain(tmp_path: Path) -> None:
    inventory = tmp_path / "domains.json"
    inventory.write_text(json.dumps({"newhost": "main"}))
    environment = runtime(tmp_path, extra={"SOPS_SECRET_DOMAINS_FILE": str(inventory)})

    with pytest.raises(ToolError, match="belongs to secret domain 'main', not 'work'"):
        environment.assert_domain_host(SecretDomain("work", None), "newhost")


def test_repository_reports_missing_secret_role(tmp_path: Path) -> None:
    repository = SecretRepository(tmp_path, SecretDomain("main", None))

    with pytest.raises(ToolError, match="Destination secret not found"):
        repository.require_secret("missing", role="Destination")
