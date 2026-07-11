import contextlib
import importlib.util
import os
import pathlib
import threading
import time
import types
from concurrent.futures import ThreadPoolExecutor

import pytest


MODULE_PATH = pathlib.Path(
    os.environ.get("SSH_TICKET_MAIN", pathlib.Path(__file__).with_name("main.py"))
)
SPEC = importlib.util.spec_from_file_location("ssh_ticket_main", MODULE_PATH)
ssh_ticket = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ssh_ticket)


def test_parse_duration_combined_units():
    assert ssh_ticket.parse_duration("30m") == 1800
    assert ssh_ticket.parse_duration("1h30m") == 5400
    assert ssh_ticket.parse_duration("2d") == 172800


@pytest.mark.parametrize("value", ["", "m30", "1x", "1h:30m"])
def test_parse_duration_rejects_invalid_values(value):
    with pytest.raises(ssh_ticket.Error):
        ssh_ticket.parse_duration(value)


def test_requested_ttl_uses_target_default():
    ttl = ssh_ticket.requested_ttl(
        types.SimpleNamespace(ttl=None),
        {"name": "srvarr", "defaultTtl": "30m", "maxTtl": "2h"},
    )

    assert ttl == 30 * 60


def test_requested_ttl_uses_explicit_value():
    ttl = ssh_ticket.requested_ttl(
        types.SimpleNamespace(ttl="45m"),
        {"name": "srvarr", "defaultTtl": "30m", "maxTtl": "2h"},
    )

    assert ttl == 45 * 60


def test_requested_ttl_rejects_value_above_target_maximum():
    with pytest.raises(ssh_ticket.Error, match="requested TTL 3h exceeds max TTL 2h"):
        ssh_ticket.requested_ttl(
            types.SimpleNamespace(ttl="3h"),
            {"name": "srvarr", "defaultTtl": "30m", "maxTtl": "2h"},
        )


def test_resolved_ca_key_defaults_to_agent_public_key():
    ca_agent, ca_key = ssh_ticket.resolved_ca_key(
        types.SimpleNamespace(ca_agent=None, ca_key=None)
    )
    assert ca_agent
    assert ca_key.name == "fleet-user-ca.pub"


def test_resolved_ca_key_treats_explicit_key_as_private_file():
    ca_agent, ca_key = ssh_ticket.resolved_ca_key(
        types.SimpleNamespace(ca_agent=None, ca_key="~/.ssh/custom-ca")
    )
    assert not ca_agent
    assert ca_key.name == "custom-ca"


def test_load_targets_requires_metadata_source(monkeypatch):
    monkeypatch.delenv("SSHT_TARGETS_FILE", raising=False)

    with pytest.raises(ssh_ticket.Error):
        ssh_ticket.load_targets()


def test_load_targets_reads_env_file(tmp_path, monkeypatch):
    targets_file = tmp_path / "targets.json"
    targets_file.write_text(
        """
        [
          {"name": "srvarr", "enabled": true},
          {"name": "beast", "enabled": true}
        ]
        """,
        encoding="utf-8",
    )
    monkeypatch.setenv("SSHT_TARGETS_FILE", str(targets_file))

    assert [target["name"] for target in ssh_ticket.load_targets()] == [
        "beast",
        "srvarr",
    ]


def test_resolve_target_accepts_unique_alias():
    targets = [
        {
            "name": "srvarr",
            "enabled": True,
            "aliases": ["srvarr"],
            "principal": "ihrachyshka@srvarr",
            "sshHost": "srvarr",
        }
    ]
    assert ssh_ticket.resolve_target(targets, "srvarr")["name"] == "srvarr"


def test_resolve_target_accepts_local_alias():
    targets = [
        {
            "name": "srvarr",
            "enabled": True,
            "aliases": ["srvarr", "srvarr.local"],
            "principal": "ihrachyshka@srvarr",
            "sshHost": "srvarr",
        }
    ]
    assert ssh_ticket.resolve_target(targets, "srvarr.local")["name"] == "srvarr"


def test_display_target_name_returns_target_name():
    assert ssh_ticket.display_target_name({"name": "srvarr"}) == "srvarr"
    assert ssh_ticket.display_target_name({"name": "beast"}) == "beast"


def test_resolve_target_rejects_ambiguous_alias():
    targets = [
        {
            "name": "beast",
            "enabled": True,
            "aliases": ["beast-alias"],
            "principal": "ihrachyshka@beast",
            "sshHost": "beast",
        },
        {
            "name": "beast-alt",
            "enabled": True,
            "aliases": ["beast-alias"],
            "principal": "ihrachyshka@beast",
            "sshHost": "beast-alt",
        },
    ]
    with pytest.raises(ssh_ticket.Error):
        ssh_ticket.resolve_target(targets, "beast-alias")


def test_existing_ticket_valid_uses_metadata(tmp_path):
    target = {
        "name": "srvarr",
        "principal": "ihrachyshka@srvarr",
    }
    paths = ssh_ticket.target_paths(target, tmp_path)
    paths["cert"].write_text("not a real cert\n", encoding="utf-8")
    ssh_ticket.write_json(
        paths["metadata"],
        {
            "target": target["name"],
            "principal": target["principal"],
            "validBefore": int(time.time()) + 3600,
        },
    )
    assert ssh_ticket.existing_ticket_valid(target, paths)


def test_ensure_ticket_serializes_concurrent_issuance(tmp_path, monkeypatch):
    target = {
        "name": "srvarr",
        "principal": "ihrachyshka@srvarr",
    }
    issue_started = threading.Event()
    second_lock_attempted = threading.Event()
    issue_calls = 0
    lock_attempts = 0
    lock_attempts_guard = threading.Lock()
    original_lock = ssh_ticket.ticket_issue_lock

    @contextlib.contextmanager
    def observed_lock(issue_target, state_dir):
        nonlocal lock_attempts
        with lock_attempts_guard:
            lock_attempts += 1
            if lock_attempts == 2:
                second_lock_attempted.set()
        with original_lock(issue_target, state_dir):
            yield

    def fake_issue_ticket(args, issue_target, state_dir, key_path):
        nonlocal issue_calls
        issue_calls += 1
        issue_started.set()
        assert second_lock_attempted.wait(timeout=5)
        paths = ssh_ticket.target_paths(issue_target, state_dir)
        paths["cert"].write_text("cert\n", encoding="utf-8")
        ssh_ticket.write_json(
            paths["metadata"],
            {
                "target": issue_target["name"],
                "principal": issue_target["principal"],
                "validBefore": int(time.time()) + 3600,
            },
        )
        return paths

    monkeypatch.setattr(ssh_ticket, "ticket_issue_lock", observed_lock)
    monkeypatch.setattr(ssh_ticket, "issue_ticket", fake_issue_ticket)
    args = types.SimpleNamespace(
        state_dir=str(tmp_path / "state"),
        key=str(tmp_path / "id_ed25519"),
        force=False,
    )

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(ssh_ticket.ensure_ticket, args, target)
        assert issue_started.wait(timeout=5)
        second = executor.submit(ssh_ticket.ensure_ticket, args, target)
        assert first.result(timeout=5) == second.result(timeout=5)

    assert issue_calls == 1


def issue_ticket_command(tmp_path, monkeypatch, *, allow_x11_forwarding=False):
    public_key = tmp_path / "id_ed25519.pub"
    public_key.write_text("ssh-ed25519 AAAATEST ssht ticket key\n", encoding="utf-8")
    calls = []

    def fake_run(cmd, *, capture=True, env=None):
        calls.append(cmd)
        return ""

    monkeypatch.setattr(ssh_ticket, "ensure_ticket_key", lambda key_path: public_key)
    monkeypatch.setattr(ssh_ticket, "run", fake_run)
    monkeypatch.setattr(ssh_ticket.time, "time", lambda: 1710000000)

    ssh_ticket.issue_ticket(
        types.SimpleNamespace(
            ttl=None,
            ca_agent=False,
            ca_key=str(tmp_path / "ca"),
        ),
        {
            "name": "frame",
            "sshHost": "frame",
            "principal": "ihrachyshka@frame",
            "defaultTtl": "30m",
            "maxTtl": "2h",
            "allowX11Forwarding": allow_x11_forwarding,
        },
        tmp_path / "state",
        tmp_path / "id_ed25519",
    )

    assert len(calls) == 1
    return calls[0]


def test_issue_ticket_disables_x11_forwarding_by_default(tmp_path, monkeypatch):
    cmd = issue_ticket_command(tmp_path, monkeypatch)

    assert "no-agent-forwarding" in cmd
    assert "no-x11-forwarding" in cmd


def test_issue_ticket_allows_x11_forwarding_for_opted_in_targets(tmp_path, monkeypatch):
    cmd = issue_ticket_command(tmp_path, monkeypatch, allow_x11_forwarding=True)

    assert "no-agent-forwarding" in cmd
    assert "permit-X11-forwarding" in cmd
    assert "no-x11-forwarding" not in cmd


def test_write_ticket_alias_copies_cert_material(tmp_path):
    paths = ssh_ticket.target_paths({"name": "org"}, tmp_path)
    paths["public"].write_text("public\n", encoding="utf-8")
    paths["cert"].write_text("cert\n", encoding="utf-8")
    paths["metadata"].write_text('{"target":"org"}\n', encoding="utf-8")

    alias_paths = ssh_ticket.write_ticket_alias(paths, "org.home.arpa", tmp_path)

    assert alias_paths["public"].name == "org.home.arpa.pub"
    assert alias_paths["cert"].name == "org.home.arpa-cert.pub"
    assert alias_paths["cert"].read_text(encoding="utf-8") == "cert\n"
    assert alias_paths["metadata"].read_text(encoding="utf-8") == ('{"target":"org"}\n')


def test_parser_has_ensure_command():
    args = ssh_ticket.build_parser().parse_args(
        ["ensure", "--quiet", "--cert-alias", "org", "org"]
    )

    assert args.func == ssh_ticket.cmd_ensure
    assert args.quiet
    assert args.cert_alias == "org"
    assert args.target == "org"


def test_ssht_command_does_not_add_ticket_key_to_agent(tmp_path):
    cmd = ssh_ticket.ssht_ssh_command(
        types.SimpleNamespace(
            key=str(tmp_path / "id_ed25519"), ssh_args=["--", "true"]
        ),
        {"sshHost": "srvarr"},
        {"cert": tmp_path / "id_ed25519-cert.pub"},
    )

    assert "AddKeysToAgent=no" in cmd
    assert cmd[-2:] == ["srvarr", "true"]
