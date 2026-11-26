import json
import os
import pathlib
import subprocess
import time
from collections.abc import Iterator

import pytest
from ssh_device import Device, Identity, OpenSSHAgent, load_identity, run
from test_selection import Connected


@pytest.fixture
def agent(tmp_path_factory: pytest.TempPathFactory) -> Iterator[OpenSSHAgent]:
    environment = os.environ | {"SSH_AUTH_SOCK": str(tmp_path_factory.mktemp("agent") / "sock")}
    with subprocess.Popen(
        ["ssh-agent", "-D", "-a", environment["SSH_AUTH_SOCK"]],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ) as process:
        try:
            deadline = time.monotonic() + 5
            while not pathlib.Path(environment["SSH_AUTH_SOCK"]).exists():
                assert process.poll() is None
                assert time.monotonic() < deadline
                time.sleep(0.01)
            yield OpenSSHAgent(environment)
        finally:
            process.terminate()
            process.wait(timeout=5)


def make_key(path: pathlib.Path, serial: str) -> Identity:
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)], check=True)
    return Identity(serial=serial, public_key=path.with_suffix(".pub").read_text())


def test_switching_keeps_only_preferred_handle_and_unrelated_keys(
    tmp_path: pathlib.Path, agent: OpenSSHAgent
) -> None:
    dock = make_key(tmp_path / "dock", "100")
    laptop = make_key(tmp_path / "laptop", "200")
    unrelated = make_key(tmp_path / "other", "300")
    handles = [tmp_path / "dock", tmp_path / "laptop"]
    discovery = Connected([Device("100", "dock"), Device("200", "laptop")])

    assert agent.fingerprints() == set()
    agent.add(tmp_path / "other")
    agent.add(tmp_path / "laptop")
    assert load_identity([dock, laptop], handles, discovery, agent) == dock
    assert agent.fingerprints() == {dock.fingerprint, unrelated.fingerprint}

    discovery.connected = [Device("200", "laptop")]
    assert load_identity([dock, laptop], handles, discovery, agent) == laptop
    assert agent.fingerprints() == {laptop.fingerprint, unrelated.fingerprint}
    assert load_identity([dock, laptop], handles, discovery, agent) == laptop

    discovery.connected = [Device("200", "laptop"), Device("100", "new-dock")]
    assert load_identity([dock, laptop], handles, discovery, agent) == dock
    assert agent.fingerprints() == {dock.fingerprint, unrelated.fingerprint}

    discovery.connected = []
    with pytest.raises(ValueError, match="No preferred"):
        load_identity([dock, laptop], handles, discovery, agent)
    assert agent.fingerprints() == {dock.fingerprint, unrelated.fingerprint}


def test_unknown_handle_is_rejected(tmp_path: pathlib.Path, agent: OpenSSHAgent) -> None:
    make_key(tmp_path / "unknown", "100")
    with pytest.raises(ValueError, match="No YubiKey inventory entry"):
        load_identity([], [tmp_path / "unknown"], Connected([]), agent)
    assert agent.fingerprints() == set()


def test_load_cli(
    tmp_path: pathlib.Path, agent: OpenSSHAgent, capsys: pytest.CaptureFixture[str]
) -> None:
    dock = make_key(tmp_path / "dock", "100")
    manifest = tmp_path / "identities.json"
    manifest.write_text(json.dumps([dock.model_dump()]))
    args = ["--identities", str(manifest), "load", str(tmp_path / "dock")]
    assert run(args, Connected([Device("100", "dock")]), agent) == 0
    assert capsys.readouterr().out == dock.public_key.strip() + "\n"
    assert agent.fingerprints() == {dock.fingerprint}


def test_unavailable_agent_reports_failure(tmp_path: pathlib.Path) -> None:
    agent = OpenSSHAgent(os.environ | {"SSH_AUTH_SOCK": str(tmp_path / "missing")})
    with pytest.raises(subprocess.CalledProcessError):
        agent.fingerprints()
