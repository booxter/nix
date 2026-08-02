from __future__ import annotations

import os
import subprocess
from pathlib import Path

import yaml

from sops_tools.model import KeyPath
from sops_tools.policy import SopsPolicy
from sops_tools.process import SubprocessRunner
from sops_tools.repository import SecretDomain, SecretRepository
from sops_tools.secrets import CommandSopsBackend, SecretService, write_atomic


def test_real_sops_operations_preserve_unrelated_ciphertext(tmp_path: Path) -> None:
    identity = tmp_path / "age.txt"
    subprocess.run(
        ["age-keygen", "-o", str(identity)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    recipient = subprocess.run(
        ["age-keygen", "-y", str(identity)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    policy = SopsPolicy.create()
    for host in ("beast", "source", "destination"):
        policy.ensure_host_rule("main", host, [recipient])
    policy.write(tmp_path / ".sops.yaml")

    repository = SecretRepository(tmp_path, SecretDomain("main", None))
    repository.directory.mkdir(parents=True)
    repository.template.write_text(
        yaml.safe_dump(
            {
                "common": {"shared": "template"},
                "new": {"value": "replace"},
            },
            sort_keys=False,
        )
    )
    host_template = repository.host_template("beast")
    host_template.parent.mkdir()
    host_template.write_text(yaml.safe_dump({"items": ["replace"]}, sort_keys=False))

    environment = {**os.environ, "SOPS_AGE_KEY_FILE": str(identity)}
    backend = CommandSopsBackend(SubprocessRunner(environment), tmp_path / ".sops.yaml")
    service = SecretService(repository, backend)
    documents = {
        "beast": {"common": {"shared": "secret"}, "keep": "beast"},
        "source": {"copied": {"token": "secret", "endpoint": "cache"}},
        "destination": {"keep": "destination"},
    }
    for host, document in documents.items():
        secret = repository.secret(host)
        write_atomic(secret, backend.encrypt_data(secret, document))

    beast = repository.secret("beast")
    original_beast = yaml.safe_load(beast.read_text())
    result = service.update("beast")
    updated_beast = yaml.safe_load(beast.read_text())

    assert result.changed and not result.reencrypted
    assert updated_beast["common"]["shared"] == original_beast["common"]["shared"]
    assert updated_beast["keep"] == original_beast["keep"]
    assert backend.decrypt_data(beast) == {
        "common": {"shared": "secret"},
        "keep": "beast",
        "new": {"value": "replace"},
        "items": ["replace"],
    }

    converged = beast.read_bytes()
    assert not service.update("beast").changed
    assert beast.read_bytes() == converged

    destination = repository.secret("destination")
    original_destination = yaml.safe_load(destination.read_text())
    service.copy(
        "source",
        "destination",
        KeyPath.parse("copied"),
        KeyPath.parse("nested/copied"),
    )
    copied_destination = yaml.safe_load(destination.read_text())
    assert copied_destination["keep"] == original_destination["keep"]

    exact_value = " leading\ntrailing spaces   \n"
    service.set_text("destination", KeyPath.parse("nested/exact"), exact_value)
    assert backend.decrypt_data(destination) == {
        "keep": "destination",
        "nested": {
            "copied": {"token": "secret", "endpoint": "cache"},
            "exact": exact_value,
        },
    }
