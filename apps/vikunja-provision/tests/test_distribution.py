from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

import pytest
import yaml
from pydantic import SecretStr
from sops_tools.cli import Application
from sops_tools.errors import ToolError
from sops_tools.model import JsonValue
from sops_tools.process import SubprocessRunner
from sops_tools.repository import RuntimeEnvironment
from sops_tools.secrets import CommandSopsBackend, SopsBackend
from vikunja_provision.distribution import TokenDistribution
from vikunja_provision.models import Credentials, Declaration, ProvisionError
from vikunja_provision.storage import SopsCredentials, SopsSecrets
from vikunja_provision.workflow import apply

from .fakes import (
    MemoryCredentials,
    MemoryTokenStore,
    MemoryVikunja,
    prepare,
    provision,
)
from .fakes import (
    seat_targets as seats,
)


def credential() -> Credentials:
    return Credentials(
        server="https://example.test", bot_id=1, token_id=1, token=SecretStr("tk_private")
    )


def test_plan_and_publish_only_selected_seats() -> None:
    store = MemoryTokenStore(values={"unselected": SecretStr("unrelated")})
    distribution = TokenDistribution(seats(), store)
    credentials = credential()

    assert len(distribution.plan(credentials)) == 3
    assert list(store.values) == ["unselected"]
    distribution.publish(credentials)

    for host in seats():
        assert store.values[host].get_secret_value() == "Bearer tk_private"

    assert store.values["unselected"].get_secret_value() == "unrelated"
    assert distribution.plan(credentials) == []
    assert len(distribution.plan(None)) == 3
    distribution.publish(credentials)
    assert distribution.plan(credentials) == []


def test_partial_distribution_stops_and_can_be_resumed() -> None:
    store = MemoryTokenStore(failing_writes={"mair"})
    distribution = TokenDistribution(seats(), store)

    with pytest.raises(ProvisionError, match="Not updated: mair, mmini") as error:
        distribution.publish(credential())

    assert set(store.values) == {"frame"}
    assert "tk_private" not in str(error.value)
    store.failing_writes.clear()
    assert len(distribution.plan(credential())) == 2
    distribution.publish(credential())
    assert distribution.plan(credential()) == []


def test_rotation_retains_old_token_until_every_sops_file_is_updated(
    declaration: Declaration,
    sops_application: Application,
) -> None:
    api = MemoryVikunja()
    secrets = SopsSecrets(sops_application)
    credentials = SopsCredentials(declaration.state, secrets)
    provision(declaration, api, credentials)
    distribution = TokenDistribution(seats(), secrets)
    initial = credentials.load()
    assert initial is not None
    distribution.publish(initial)
    # Losing a seat file after preflight interrupts distribution after frame is updated.
    root = sops_application.runtime.repo_root
    missing = root / "secrets" / "home" / "mair.yaml"
    backup = root / "mair.saved.yaml"
    missing.rename(backup)

    with pytest.raises(ProvisionError, match="SOPS distribution stopped"):
        apply(
            declaration,
            prepare(declaration, api, credentials, rotate=True),
            api,
            credentials,
            distribution,
        )

    assert [token.id for token in api.tokens(1)] == [1, 2]
    # Recreate all stores to prove that recovery depends only on encrypted state.
    resumed_secrets = SopsSecrets(Application(sops_application.runtime))
    resumed = SopsCredentials(declaration.state, resumed_secrets)
    pending = resumed.load()
    assert pending is not None
    assert pending.token_id == 2
    assert pending.previous_token_id == 1
    assert "tk_secret_2" not in (root / "secrets" / "home" / "org.yaml").read_text()

    backup.rename(missing)
    distribution = TokenDistribution(seats(), resumed_secrets)
    apply(declaration, prepare(declaration, api, resumed), api, resumed, distribution)

    assert [token.id for token in api.tokens(1)] == [2]
    complete = resumed.load()
    assert complete is not None
    assert complete.previous_token_id is None
    assert distribution.plan(complete) == []


def test_failed_initial_sops_save_revokes_replacement_and_preserves_old_token(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja()
    secrets = MemoryTokenStore()
    credentials = SopsCredentials(declaration.state, secrets)
    provision(declaration, api, credentials)
    saved = credentials.load()
    secrets.failing_writes.add("org")

    with pytest.raises(ProvisionError, match="revoked the newly issued token"):
        apply(declaration, prepare(declaration, api, credentials, rotate=True), api, credentials)

    assert [token.id for token in api.tokens(1)] == [1]
    assert credentials.load() == saved


def test_first_token_distribution_can_be_retried_without_minting_another(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja()
    credentials = MemoryCredentials()
    token_store = MemoryTokenStore(failing_reads={"frame"})
    distribution = TokenDistribution(seats(), token_store)

    with pytest.raises(ProvisionError, match="distribution stopped"):
        apply(declaration, prepare(declaration, api, credentials), api, credentials, distribution)

    token_store.failing_reads.clear()
    apply(declaration, prepare(declaration, api, credentials), api, credentials, distribution)
    assert len(api.tokens(1)) == 1
    assert distribution.plan(credentials.credentials) == []


def test_rotation_finishes_if_old_token_was_already_revoked(declaration: Declaration) -> None:
    api = MemoryVikunja()
    credentials = MemoryCredentials()
    provision(declaration, api, credentials)
    assert credentials.credentials is not None
    credentials.credentials.previous_token_id = 1234

    provision(declaration, api, credentials)
    assert credentials.credentials.previous_token_id is None
    assert len(api.tokens(1)) == 1


def runtime(tmp_path: Path, values: dict[str, str]) -> RuntimeEnvironment:
    return RuntimeEnvironment(
        repo_root=tmp_path,
        home=tmp_path,
        config_home=tmp_path / ".config",
        system_name="Linux",
        hostname="mair",
        values=values,
    )


@pytest.fixture
def sops_application(tmp_path: Path) -> Application:
    key = tmp_path / "identity.txt"
    runner = SubprocessRunner(environment={"SOPS_AGE_KEY_FILE": str(key)})
    runner.run(["age-keygen", "-o", str(key)])
    recipient = runner.run(["age-keygen", "-y", str(key)]).strip()
    config = tmp_path / ".sops.yaml"
    config.write_text(
        yaml.safe_dump(
            {"creation_rules": [{"path_regex": r"secrets/.*\.yaml$", "age": recipient}]}
        ),
        encoding="utf-8",
    )
    backend = CommandSopsBackend(runner, config)
    for host in ["org", *seats()]:
        path = tmp_path / "secrets" / "home" / f"{host}.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(backend.encrypt_data(path, {"unrelated": "keep"}), encoding="utf-8")

    return Application(runtime(tmp_path, {"SOPS_AGE_KEY_FILE": str(key)}))


def test_real_sops_updates_encrypted_files_idempotently(sops_application: Application) -> None:
    store = SopsSecrets(sops_application)
    backend = sops_application.secrets("home").sops
    distribution = TokenDistribution(seats(), store)
    assert len(distribution.plan(credential())) == 3
    distribution.publish(credential())

    for host, target in seats().items():
        path = sops_application.runtime.repo_root / "secrets" / "home" / f"{host}.yaml"
        ciphertext = path.read_text()
        assert "tk_private" not in ciphertext
        assert store.read(host, target) == SecretStr("Bearer tk_private")
        assert backend.decrypt_data(path) == {
            "unrelated": "keep",
            "agents": {"vikunja": {"org": {"agents": {"authorization": "Bearer tk_private"}}}},
        }
        distribution.publish(credential())
        assert path.read_text() == ciphertext


@dataclass(frozen=True)
class FailingRunner:
    def run(
        self, argv: Sequence[str], *, input_text: str | None = None, capture_output: bool = True
    ) -> str:
        raise ToolError("sops echoed tk_private")

    def run_streaming(self, argv: Sequence[str]) -> str:
        raise ToolError("sops echoed tk_private")


class FailingBackendFactory:
    def create(self, environment: Mapping[str, str], config: Path) -> SopsBackend:
        return CommandSopsBackend(FailingRunner(), config)


def test_sops_errors_do_not_disclose_subprocess_output(tmp_path: Path) -> None:
    path = tmp_path / "secrets" / "home" / "mair.yaml"
    path.parent.mkdir(parents=True)
    path.touch()
    store = SopsSecrets(Application(runtime(tmp_path, {}), FailingBackendFactory()))
    target = seats()["mair"]

    with pytest.raises(ProvisionError, match="Could not read SOPS") as error:
        store.read("mair", target)
    assert "tk_private" not in str(error.value)

    with pytest.raises(ProvisionError, match="Could not update SOPS") as error:
        store.write("mair", target, SecretStr("Bearer tk_private"))
    assert "tk_private" not in str(error.value)


def test_nonstring_sops_destination_is_rejected(tmp_path: Path) -> None:
    class NonstringBackend(CommandSopsBackend):
        def decrypt_data(self, path: Path) -> JsonValue:
            return {"agents": {"vikunja": {"org": {"agents": {"authorization": 123}}}}}

    class BackendFactory:
        def create(self, environment: Mapping[str, str], config: Path) -> SopsBackend:
            return NonstringBackend(FailingRunner(), config)

    path = tmp_path / "secrets" / "home" / "mair.yaml"
    path.parent.mkdir(parents=True)
    path.touch()
    store = SopsSecrets(Application(runtime(tmp_path, {}), BackendFactory()))
    with pytest.raises(ProvisionError, match="must be a string"):
        store.read("mair", seats()["mair"])
