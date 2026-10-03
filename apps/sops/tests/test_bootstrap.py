from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from sops_tools.bootstrap import BootstrapService, CommandHostRecipientProvider
from sops_tools.errors import ToolError
from sops_tools.policy import SopsPolicy
from sops_tools.repository import Realm, RuntimeEnvironment, SecretRepository

from .fakes import (
    MemorySopsBackend,
    RecordingRunner,
    StaticHostRecipientProvider,
    StaticOperatorRecipientProvider,
)


def service(
    tmp_path: Path, hosts: tuple[str, ...] = ("newhost", "secondhost")
) -> tuple[BootstrapService, MemorySopsBackend, StaticHostRecipientProvider]:
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
    host_recipients = StaticHostRecipientProvider(values={"pki": "age1pki"})
    return (
        BootstrapService(
            runtime,
            repository,
            backend,
            host_recipients,
            StaticOperatorRecipientProvider(),
        ),
        backend,
        host_recipients,
    )


def test_bootstrap_creates_policy_and_encrypted_template(tmp_path: Path) -> None:
    bootstrap, backend, host_recipients = service(tmp_path)

    result = bootstrap.bootstrap("newhost")

    assert result.messages == (
        "Created .sops.yaml.",
        "Created encrypted secrets/home/newhost.yaml.",
    )
    assert host_recipients.calls == ["newhost", "pki"]
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert policy.keys == ["age1host", "age1operator", "age1pki"]
    assert policy.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1host",
        "age1operator",
        "age1pki",
    ]
    secret = bootstrap.repository.secret("newhost")
    assert backend.documents[secret] == {"bootstrap": {"token": "replace"}}


def test_bootstrap_appends_hosts_and_does_not_rewrite_existing_secret(
    tmp_path: Path,
) -> None:
    bootstrap, backend, _ = service(tmp_path)
    bootstrap.bootstrap("newhost")
    first_encryption_count = len(backend.encryptions)

    repeated = bootstrap.bootstrap("newhost")
    bootstrap.bootstrap("secondhost")

    assert repeated.messages[-1] == "secrets/home/newhost.yaml already exists."
    assert len(backend.encryptions) == first_encryption_count + 1
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert len(policy.creation_rules) == 2
    assert policy.keys == ["age1host", "age1operator", "age1pki"]


def test_bootstrap_creates_merged_secret_without_contacting_host(tmp_path: Path) -> None:
    bootstrap, backend, host_recipients = service(tmp_path)
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

    result = bootstrap.bootstrap("newhost")

    assert result.messages == (
        "Created .sops.yaml.",
        "Created encrypted secrets/home/newhost.yaml.",
    )
    assert host_recipients.calls == ["newhost", "pki"]
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert policy.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1host",
        "age1operator",
        "age1pki",
    ]
    assert backend.documents[bootstrap.repository.secret("newhost")] == {
        "bootstrap": {"token": "replace", "host": "replace"},
        "github": {"token": "replace"},
    }


def test_bootstrap_adds_host_recipient_to_existing_secret(tmp_path: Path) -> None:
    bootstrap, backend, _ = service(tmp_path)
    policy = SopsPolicy.create()
    policy.ensure_host_rule("home", "newhost", ["age1operator"])
    policy.write(tmp_path / ".sops.yaml")
    secret = bootstrap.repository.secret("newhost")
    secret.write_text("encrypted\n")
    backend.documents[secret] = {"bootstrap": {"token": "secret"}}

    result = bootstrap.bootstrap("newhost")

    assert result.messages[-1] == ("Re-encrypted secrets/home/newhost.yaml for updated recipients.")
    assert len(backend.encryptions) == 1
    policy = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert policy.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1operator",
        "age1host",
        "age1pki",
    ]


def test_failed_reencryption_restores_policy_for_retry(tmp_path: Path) -> None:
    bootstrap, backend, _ = service(tmp_path)
    policy = SopsPolicy.create()
    policy.ensure_host_rule("home", "newhost", ["age1operator"])
    policy.write(tmp_path / ".sops.yaml")
    secret = bootstrap.repository.secret("newhost")
    secret.write_text("encrypted\n")
    backend.documents[secret] = {"bootstrap": {"token": "secret"}}
    policy_path = tmp_path / ".sops.yaml"
    seeded_policy = policy_path.read_text()
    backend.fail_encryption = True

    with pytest.raises(ToolError, match="Unable to encrypt"):
        bootstrap.bootstrap("newhost")

    assert policy_path.read_text() == seeded_policy
    backend.fail_encryption = False
    result = bootstrap.bootstrap("newhost")
    assert result.messages[-1].startswith("Re-encrypted ")


def test_home_bootstrap_uses_pki_host_recipient_for_control_plane(tmp_path: Path) -> None:
    bootstrap, _, host_recipients = service(tmp_path)

    bootstrap.bootstrap("newhost")

    updated = SopsPolicy.load(tmp_path / ".sops.yaml")
    assert updated.recipients_for_rule("secrets/home/newhost\\.yaml$") == [
        "age1host",
        "age1operator",
        "age1pki",
    ]
    assert host_recipients.calls == ["newhost", "pki"]


def test_host_recipient_is_derived_from_committed_public_key(tmp_path: Path) -> None:
    public_key = tmp_path / "nixos/newhost/ssh_host_ed25519_key.pub"
    public_key.parent.mkdir(parents=True)
    public_key.write_text("ssh-ed25519 public-key newhost\n")
    runner = RecordingRunner(outputs=["age1host\n"])
    provider = CommandHostRecipientProvider(runner, tmp_path)

    assert provider.recipient("newhost") == "age1host"
    command = runner.calls[0][0]
    assert Path(command[0]).name == "ssh-to-age"
    assert command[1:] == ["-i", str(public_key)]


def test_host_recipient_requires_committed_public_key(tmp_path: Path) -> None:
    provider = CommandHostRecipientProvider(RecordingRunner(), tmp_path)

    with pytest.raises(ToolError, match="No committed Ed25519 SSH host key"):
        provider.recipient("newhost")
