import json
import os
import subprocess
import sys
import time

import pytest


def run(arguments, env, *, check=True):
    return subprocess.run(arguments, env=env, text=True, capture_output=True, check=check)


@pytest.fixture
def agent(tmp_path_factory):
    env = {key: value for key, value in os.environ.items() if not key.startswith(("SSH_", "SSHT_"))}
    # pytest's per-test directory names exceed Darwin's Unix socket path limit.
    env["SSH_AUTH_SOCK"] = str(tmp_path_factory.mktemp("agent") / "sock")
    with subprocess.Popen(
        ["ssh-agent", "-D", "-a", env["SSH_AUTH_SOCK"]],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    ) as process:
        try:
            deadline = time.monotonic() + 5
            while run(["ssh-add", "-l"], env, check=False).returncode == 2:
                assert process.poll() is None, process.stderr.read().decode()
                assert time.monotonic() < deadline, "agent did not start"
                time.sleep(0.01)
            yield env
        finally:
            process.terminate()
            process.wait(timeout=5)


@pytest.fixture
def ticket(tmp_path, agent):
    # Disposable software keys exercise agent loading without requiring hardware.
    for name in ("ca", "hardware"):
        run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(tmp_path / name)],
            agent,
        )
    targets = tmp_path / "targets.json"
    targets.write_text(json.dumps([{"name": "frame", "principal": "operator@frame"}]))
    return [
        sys.executable,
        "-m",
        "ssh_ticket.app",
        "ensure",
        "--targets-file",
        str(targets),
        "--state-dir",
        str(tmp_path / "state"),
        "--key",
        str(tmp_path / "ticket"),
        "--ca-key",
        str(tmp_path / "ca"),
        "--no-ca-agent",
        "--agent-identity",
        str(tmp_path / "hardware"),
        "--quiet",
        "frame",
    ]


def test_ticket_restores_forwarded_identity_without_loading_ticket_key(tmp_path, agent, ticket):
    expected = (tmp_path / "hardware.pub").read_text().split()[:2]
    run(ticket, agent)
    assert run(["ssh-add", "-L"], agent).stdout.split()[:2] == expected
    cert_path = tmp_path / "state" / "frame-cert.pub"
    certificate = cert_path.read_bytes()

    # A fresh agent has no identities even though the certificate is still valid.
    run(["ssh-add", "-D"], agent)
    run(ticket, agent)
    identities = run(["ssh-add", "-L"], agent).stdout.splitlines()
    assert len(identities) == 1
    assert identities[0].split()[:2] == expected
    assert cert_path.read_bytes() == certificate

    # Repeated connections keep using the same ticket and agent identity.
    run(ticket, agent)
    assert run(["ssh-add", "-L"], agent).stdout.splitlines() == identities
    assert cert_path.read_bytes() == certificate


def test_remote_session_does_not_load_destination_identity(tmp_path, agent, ticket):
    run(ticket, agent)
    run(["ssh-add", "-D"], agent)
    (tmp_path / "hardware").unlink()

    remote_env = agent | {"SSH_CONNECTION": "192.0.2.1 1234 192.0.2.2 22"}
    run(ticket, remote_env)

    assert run(["ssh-add", "-l"], agent, check=False).returncode == 1


def test_cached_ticket_reports_unavailable_local_agent(tmp_path, agent, ticket):
    run(ticket, agent)
    unavailable_env = agent | {"SSH_AUTH_SOCK": str(tmp_path / "missing.sock")}

    result = run(ticket, unavailable_env, check=False)

    assert result.returncode == 1
    assert "ssh-ticket: command failed: ssh-add" in result.stderr
