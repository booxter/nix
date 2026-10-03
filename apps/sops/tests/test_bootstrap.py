from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from sops_tools.bootstrap import BootstrapService, CommandRuntimeKeyProvider
from sops_tools.errors import ToolError
from sops_tools.policy import SopsPolicy
from sops_tools.repository import Realm, RuntimeEnvironment, SecretRepository

from .fakes import (
    MemorySopsBackend,
    RecordingRunner,
    StaticOperatorRecipientProvider,
    StaticRuntimeKeyProvider,
)


def service(
    tmp_path: Path, hosts: tuple[str, ...] = ("newhost", "secondhost")
) -> tuple[BootstrapService, MemorySopsBackend, StaticRuntimeKeyProvider]:
    inventory = tmp_path / "realms.json"
    inventory.write_text(json.dumps(dict.fromkeys(hosts, "home")))
    runtime = RuntimeEnvironment(
        repo_root=tmp_path,
        home=tmp_path / "home",
        config_home=tmp_path / "home/.config",
        system_name="Linux",
        hostname="controller",
        values={"SOPS_REALMS_FILE": str(inventory)},
    )
    repository = SecretRepository(tmp_path, Realm("home", None))
    repository.directory.mkdir(parents=True)
    repository.template.write_text(
        yaml.safe_dump({"bootstrap": {"token": "replace"}}, sort_keys=False)
    )
    backend = MemorySopsBackend({})
    runtime_keys = StaticRuntimeKeyProvider()
    return (
        BootstrapService(
            runtime,
            repository,
            backend,
            runtime_keys,
            StaticOperatorRecipientProvider(),
        ),
        backend,
        runtime_keys,
    )


def test_bootstrap_creates_policy_and_encrypted_template(tmp_path: Path) -> None:
    bootstrap, backend, runtime_keys = service(tmp_path)

    result = bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)

    assert result.messages == (
        "Created .sops.yaml.",
        "Created encrypted secrets/home/newhost.yaml.",
    )
    assert runtime_keys.calls == [("newhost", "operator", True)]
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert policy.keys == ["age1runtime", "age1operator"]
    assert policy.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1runtime",
        "age1operator",
    ]
    secret = bootstrap.repository.secret("newhost")
    assert backend.documents[secret] == {"bootstrap": {"token": "replace"}}


def test_bootstrap_appends_hosts_and_does_not_rewrite_existing_secret(
    tmp_path: Path,
) -> None:
    bootstrap, backend, _ = service(tmp_path)
    bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)
    first_encryption_count = len(backend.encryptions)

    repeated = bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)
    bootstrap.bootstrap("secondhost", "operator", local=True, has_tty=False)

    assert repeated.messages[-1] == "secrets/home/newhost.yaml already exists."
    assert len(backend.encryptions) == first_encryption_count + 1
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert len(policy.creation_rules) == 2
    assert policy.keys == ["age1runtime", "age1operator"]


def test_seed_creates_merged_secret_without_requesting_runtime_key(tmp_path: Path) -> None:
    bootstrap, backend, runtime_keys = service(tmp_path)
    bootstrap.repository.host_template("newhost").parent.mkdir(parents=True)
    bootstrap.repository.host_template("newhost").write_text(
        yaml.safe_dump(
            {
                "bootstrap": {"host": "replace"},
                "github": {"token": "replace"},
            },
            sort_keys=False,
        )
    )

    result = bootstrap.seed("newhost")

    assert result.messages == (
        "Created .sops.yaml.",
        "Created encrypted secrets/home/newhost.yaml.",
    )
    assert runtime_keys.calls == []
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert policy.recipients_for_rule("secrets/home/newhost\\.yaml$") == ["age1operator"]
    assert backend.documents[bootstrap.repository.secret("newhost")] == {
        "bootstrap": {"token": "replace", "host": "replace"},
        "github": {"token": "replace"},
    }


def test_bootstrap_adds_runtime_recipient_to_existing_seed(tmp_path: Path) -> None:
    bootstrap, backend, _ = service(tmp_path)
    bootstrap.seed("newhost")

    result = bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)

    assert result.messages[-1] == ("Re-encrypted secrets/home/newhost.yaml for updated recipients.")
    assert len(backend.encryptions) == 2
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert policy.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1operator",
        "age1runtime",
    ]


def test_failed_reencryption_restores_policy_for_retry(tmp_path: Path) -> None:
    bootstrap, backend, _ = service(tmp_path)
    bootstrap.seed("newhost")
    policy_path = tmp_path / ".sops.yaml"
    seeded_policy = policy_path.read_text()
    backend.fail_encryption = True

    with pytest.raises(ToolError, match="Unable to encrypt"):
        bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)

    assert policy_path.read_text() == seeded_policy
    backend.fail_encryption = False
    result = bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)
    assert result.messages[-1].startswith("Re-encrypted ")


def test_remote_bootstrap_requires_tty_before_key_provider(tmp_path: Path) -> None:
    bootstrap, _, runtime_keys = service(tmp_path)

    with pytest.raises(ToolError, match="no TTY available"):
        bootstrap.bootstrap("newhost", "operator", local=False, has_tty=False)

    assert runtime_keys.calls == []


def test_main_bootstrap_inherits_control_plane_recipient(tmp_path: Path) -> None:
    bootstrap, _, _ = service(tmp_path)
    policy = SopsPolicy.create()
    policy.ensure_host_rule("home", "pki", ["age1pki", "age1operator"])
    policy.write(tmp_path / ".sops.yaml")

    bootstrap.bootstrap("newhost", "operator", local=True, has_tty=False)

    updated = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert updated.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1runtime",
        "age1operator",
        "age1pki",
    ]


def test_remote_runtime_key_reads_only_public_recipient() -> None:
    runner = RecordingRunner(
        outputs=["1000\n"],
        streaming_outputs=["age1remote\r\n"],
    )
    provider = CommandRuntimeKeyProvider(runner)

    assert provider.recipient("newhost", "operator", local=False) == "age1remote"

    assert runner.calls[0][0] == [
        "ssh",
        "operator@newhost",
        "id",
        "-u",
    ]
    assert runner.streaming_calls[0] == [
        "ssh",
        "-tt",
        "operator@newhost",
        "sudo -H /run/current-system/sw/bin/sed -n "
        "'s/^# public key: //p' /var/lib/sops-nix/key.txt",
    ]
