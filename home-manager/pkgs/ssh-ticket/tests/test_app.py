import json
import pathlib
import sys
import threading
import types
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import NoReturn, Sequence

import pytest

from ssh_ticket import app as ssh_ticket
from ssh_ticket.models import Target, TicketMetadata
from ssh_ticket.runtime import CommandError, Runtime, SystemCommands


@dataclass(frozen=True)
class FrozenClock:
    timestamp: int = 1_710_000_000

    def now(self) -> int:
        return self.timestamp


@dataclass
class RecordingCommands:
    calls: list[list[str]] = field(default_factory=list)

    def run(self, arguments: Sequence[str], *, capture: bool = True) -> str:
        self.calls.append(list(arguments))
        return ""

    def exec(self, arguments: Sequence[str]) -> NoReturn:
        raise AssertionError(f"unexpected exec: {arguments!r}")


def runtime(commands=None, *, timestamp=1_710_000_000):
    return Runtime(
        commands=commands or RecordingCommands(),
        clock=FrozenClock(timestamp),
    )


def target(name="srvarr", **overrides):
    values = {
        "name": name,
        "enabled": True,
        "ssh_host": name,
        "principal": f"ihrachyshka@{name}",
    }
    values.update(overrides)
    return Target.model_validate(values)


def write_targets_file(path, targets):
    path.write_text(
        json.dumps([item.model_dump(by_alias=True) for item in targets]),
        encoding="utf-8",
    )


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
        target(default_ttl="30m", max_ttl="2h"),
    )

    assert ttl == 30 * 60


def test_requested_ttl_uses_explicit_value():
    ttl = ssh_ticket.requested_ttl(
        types.SimpleNamespace(ttl="45m"),
        target(default_ttl="30m", max_ttl="2h"),
    )

    assert ttl == 45 * 60


def test_requested_ttl_rejects_value_above_target_maximum():
    with pytest.raises(ssh_ticket.Error, match="requested TTL 3h exceeds max TTL 2h"):
        ssh_ticket.requested_ttl(
            types.SimpleNamespace(ttl="3h"),
            target(default_ttl="30m", max_ttl="2h"),
        )


def test_resolved_ca_key_defaults_to_agent_public_key(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    ca_agent, ca_key = ssh_ticket.resolved_ca_key(types.SimpleNamespace(ca_agent=None, ca_key=None))
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

    assert [target.name for target in ssh_ticket.load_targets()] == [
        "beast",
        "srvarr",
    ]


@pytest.mark.parametrize(
    "payload",
    [
        '{"name":"frame"}',
        '[{"name":""}]',
        '[{"name":"frame","defaultTtl":"3h","maxTtl":"2h"}]',
        '[{"name":"frame","unexpected":true}]',
    ],
)
def test_load_targets_rejects_invalid_models(tmp_path, payload):
    targets_file = tmp_path / "targets.json"
    targets_file.write_text(payload, encoding="utf-8")

    with pytest.raises(ssh_ticket.Error, match="failed to parse targets file"):
        ssh_ticket.load_targets_from_file(targets_file)


def test_resolve_target_accepts_unique_alias():
    targets = [target(aliases=["srvarr"])]
    assert ssh_ticket.resolve_target(targets, "srvarr").name == "srvarr"


def test_resolve_target_accepts_local_alias():
    targets = [target(aliases=["srvarr", "srvarr.local"])]
    assert ssh_ticket.resolve_target(targets, "srvarr.local").name == "srvarr"


def test_resolve_target_rejects_ambiguous_alias():
    targets = [
        target("beast", aliases=["beast-alias"]),
        target("beast-alt", aliases=["beast-alias"]),
    ]
    with pytest.raises(ssh_ticket.Error):
        ssh_ticket.resolve_target(targets, "beast-alias")


def test_resolve_target_rejects_disabled_target():
    with pytest.raises(ssh_ticket.Error, match="host.sshTicket.enable is false"):
        ssh_ticket.resolve_target([target(enabled=False)], "srvarr")


def test_resolve_target_reports_enabled_targets_for_unknown_name():
    with pytest.raises(ssh_ticket.Error, match="enabled targets: srvarr"):
        ssh_ticket.resolve_target([target()], "missing")


def test_existing_ticket_valid_uses_metadata(tmp_path):
    ticket_target = target()
    paths = ssh_ticket.target_paths(ticket_target.name, tmp_path)
    paths.cert.write_text("not a real cert\n", encoding="utf-8")
    ssh_ticket.write_metadata(
        paths.metadata,
        TicketMetadata(
            target=ticket_target.name,
            principal=ticket_target.principal,
            valid_before=1_710_003_600,
        ),
    )
    assert paths.metadata.stat().st_mode & 0o777 == 0o600
    assert not list(tmp_path.glob(".srvarr.json.*"))
    assert ssh_ticket.existing_ticket_valid(ticket_target, paths, runtime())


def test_ticket_status_distinguishes_missing_expired_and_valid(tmp_path):
    ticket_target = target()
    test_runtime = runtime()

    assert ssh_ticket.ticket_status(ticket_target, tmp_path, test_runtime).status == "missing"

    paths = ssh_ticket.target_paths(ticket_target.name, tmp_path)
    paths.cert.write_text("cert\n", encoding="utf-8")
    ssh_ticket.write_metadata(
        paths.metadata,
        TicketMetadata(
            target=ticket_target.name,
            principal=ticket_target.principal,
            valid_before=1_710_000_060,
        ),
    )
    expired = ssh_ticket.ticket_status(ticket_target, tmp_path, test_runtime)
    assert expired.status == "expired"
    assert expired.valid_before == 1_710_000_060

    ssh_ticket.write_metadata(
        paths.metadata,
        TicketMetadata(
            target=ticket_target.name,
            principal=ticket_target.principal,
            valid_before=1_710_003_600,
        ),
    )
    assert ssh_ticket.ticket_status(ticket_target, tmp_path, test_runtime).status == "valid"


def test_read_metadata_treats_invalid_json_as_missing(tmp_path):
    metadata = tmp_path / "ticket.json"
    metadata.write_text("not json\n", encoding="utf-8")

    assert ssh_ticket.read_metadata(metadata) is None


@dataclass
class KeygenCommands(RecordingCommands):
    def run(self, arguments: Sequence[str], *, capture: bool = True) -> str:
        super().run(arguments, capture=capture)
        if "-t" in arguments:
            key_path = pathlib.Path(arguments[-1])
            key_path.write_text("private\n", encoding="utf-8")
            pathlib.Path(f"{key_path}.pub").write_text("public\n", encoding="utf-8")
            return ""
        return "public from private\n"


def test_ensure_ticket_key_generates_missing_keypair(tmp_path):
    commands = KeygenCommands()
    key_path = tmp_path / "keys" / "id_ed25519"

    public_path = ssh_ticket.ensure_ticket_key(key_path, runtime(commands))

    assert public_path.read_text(encoding="utf-8") == "public\n"
    assert key_path.stat().st_mode & 0o777 == 0o600
    assert commands.calls[0][1:4] == ["-q", "-t", "ed25519"]


def test_ensure_ticket_key_recovers_missing_public_key(tmp_path):
    commands = RecordingCommands()
    key_path = tmp_path / "id_ed25519"
    key_path.write_text("private\n", encoding="utf-8")

    public_path = ssh_ticket.ensure_ticket_key(key_path, runtime(commands))

    assert public_path.read_text(encoding="utf-8") == ""
    assert commands.calls == [["ssh-keygen", "-y", "-f", str(key_path)]]


def test_ensure_ticket_serializes_concurrent_issuance(tmp_path):
    ticket_target = target(default_ttl="30m", max_ttl="2h")
    key_path = tmp_path / "id_ed25519"
    key_path.write_text("private\n", encoding="utf-8")
    key_path.with_suffix(".pub").write_text("public\n", encoding="utf-8")
    commands = CoordinatedSigningCommands()
    test_runtime = runtime(commands)
    args = types.SimpleNamespace(
        state_dir=str(tmp_path / "state"),
        key=str(key_path),
        force=False,
        ttl=None,
        ca_agent=False,
        ca_key=str(tmp_path / "ca"),
    )

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(ssh_ticket.ensure_ticket, args, ticket_target, test_runtime)
        assert commands.signing_started.wait(timeout=5)
        second = executor.submit(ssh_ticket.ensure_ticket, args, ticket_target, test_runtime)
        assert not commands.second_signing.wait(timeout=0.2)
        commands.release_signing.set()
        assert first.result(timeout=5) == second.result(timeout=5)

    assert commands.signing_calls == 1


@dataclass
class CoordinatedSigningCommands:
    signing_started: threading.Event = field(default_factory=threading.Event)
    second_signing: threading.Event = field(default_factory=threading.Event)
    release_signing: threading.Event = field(default_factory=threading.Event)
    signing_calls: int = 0
    _guard: threading.Lock = field(default_factory=threading.Lock)

    def run(self, arguments: Sequence[str], *, capture: bool = True) -> str:
        with self._guard:
            self.signing_calls += 1
            call_number = self.signing_calls
        if call_number > 1:
            self.second_signing.set()
        self.signing_started.set()
        assert self.release_signing.wait(timeout=5)
        public_path = arguments[-1]
        cert_path = public_path.removesuffix(".pub") + "-cert.pub"
        ssh_ticket.pathlib.Path(cert_path).write_text("cert\n", encoding="utf-8")
        return ""

    def exec(self, arguments: Sequence[str]) -> NoReturn:
        raise AssertionError(f"unexpected exec: {arguments!r}")


def issue_ticket_command(tmp_path, *, allow_x11_forwarding=False):
    key_path = tmp_path / "id_ed25519"
    key_path.write_text("private\n", encoding="utf-8")
    public_key = tmp_path / "id_ed25519.pub"
    public_key.write_text("ssh-ed25519 AAAATEST ssht ticket key\n", encoding="utf-8")
    commands = RecordingCommands()

    ssh_ticket.issue_ticket(
        types.SimpleNamespace(
            ttl=None,
            ca_agent=False,
            ca_key=str(tmp_path / "ca"),
        ),
        target(
            "frame",
            default_ttl="30m",
            max_ttl="2h",
            allow_x11_forwarding=allow_x11_forwarding,
        ),
        tmp_path / "state",
        key_path,
        runtime(commands),
    )

    assert len(commands.calls) == 1
    return commands.calls[0]


def test_issue_ticket_disables_x11_forwarding_by_default(tmp_path):
    cmd = issue_ticket_command(tmp_path)

    assert "no-agent-forwarding" in cmd
    assert "no-x11-forwarding" in cmd


def test_issue_ticket_allows_x11_forwarding_for_opted_in_targets(tmp_path):
    cmd = issue_ticket_command(tmp_path, allow_x11_forwarding=True)

    assert "no-agent-forwarding" in cmd
    assert "permit-X11-forwarding" in cmd
    assert "no-x11-forwarding" not in cmd


def test_write_ticket_alias_copies_cert_material(tmp_path):
    paths = ssh_ticket.target_paths("org", tmp_path)
    paths.public.write_text("public\n", encoding="utf-8")
    paths.cert.write_text("cert\n", encoding="utf-8")
    paths.metadata.write_text('{"target":"org"}\n', encoding="utf-8")

    alias_paths = ssh_ticket.write_ticket_alias(paths, "org.home.arpa", tmp_path)

    assert alias_paths.public.name == "org.home.arpa.pub"
    assert alias_paths.cert.name == "org.home.arpa-cert.pub"
    assert alias_paths.cert.read_text(encoding="utf-8") == "cert\n"
    assert alias_paths.metadata.read_text(encoding="utf-8") == '{"target":"org"}\n'


def test_targets_command_emits_only_enabled_targets_by_default(tmp_path, capsys):
    targets_file = tmp_path / "targets.json"
    write_targets_file(targets_file, [target("beast", enabled=False), target()])

    result = ssh_ticket.main(["targets", "--targets-file", str(targets_file), "--json"], runtime())

    assert result == 0
    payload = json.loads(capsys.readouterr().out)
    assert [item["name"] for item in payload] == ["srvarr"]


def test_status_command_reports_expired_ticket(tmp_path, capsys):
    ticket_target = target()
    targets_file = tmp_path / "targets.json"
    state_dir = tmp_path / "state"
    write_targets_file(targets_file, [ticket_target])
    paths = ssh_ticket.target_paths(ticket_target.name, state_dir)
    state_dir.mkdir()
    paths.cert.write_text("cert\n", encoding="utf-8")
    ssh_ticket.write_metadata(
        paths.metadata,
        TicketMetadata(
            target=ticket_target.name,
            principal=ticket_target.principal,
            valid_before=1_710_000_060,
        ),
    )

    result = ssh_ticket.main(
        [
            "status",
            "--targets-file",
            str(targets_file),
            "--state-dir",
            str(state_dir),
            "srvarr",
        ],
        runtime(),
    )

    assert result == 0
    assert "srvarr: expired (expired " in capsys.readouterr().out


@dataclass
class FailingCommands(RecordingCommands):
    def run(self, arguments: Sequence[str], *, capture: bool = True) -> str:
        raise CommandError("signing failed")


def test_main_reports_command_failure(tmp_path, capsys):
    result = ssh_ticket.main(
        ["init-key", "--key", str(tmp_path / "id_ed25519")],
        runtime(FailingCommands()),
    )

    assert result == 1
    assert capsys.readouterr().err == "ssh-ticket: signing failed\n"


def test_system_commands_capture_output_and_report_failure(capsys):
    commands = SystemCommands()

    assert commands.run([sys.executable, "-c", "print('ticket')"]) == "ticket\n"
    with pytest.raises(CommandError, match="command failed"):
        commands.run(
            [sys.executable, "-c", "import sys; sys.stderr.write('failed\\n'); sys.exit(2)"]
        )
    assert capsys.readouterr().err == "failed\n"


def test_parser_has_ensure_command():
    args = ssh_ticket.build_parser().parse_args(["ensure", "--quiet", "--cert-alias", "org", "org"])

    assert args.func == ssh_ticket.cmd_ensure
    assert args.quiet
    assert args.cert_alias == "org"
    assert args.target == "org"


def test_ssht_command_does_not_add_ticket_key_to_agent(tmp_path):
    cmd = ssh_ticket.ssht_ssh_command(
        types.SimpleNamespace(key=str(tmp_path / "id_ed25519"), ssh_args=["--", "true"]),
        target(),
        ssh_ticket.TicketPaths(
            public=tmp_path / "id_ed25519.pub",
            cert=tmp_path / "id_ed25519-cert.pub",
            metadata=tmp_path / "id_ed25519.json",
        ),
    )

    assert "AddKeysToAgent=no" in cmd
    assert cmd[-2:] == ["srvarr", "true"]
