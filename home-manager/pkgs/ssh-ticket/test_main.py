import importlib.util
import os
import pathlib
import time
import types

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


def test_applescript_string_renders_newlines_as_linefeed():
    expr = ssh_ticket.applescript_string('one\n\nquoted "value"')
    assert "\\n" not in expr
    assert expr == '"one" & linefeed & "" & linefeed & "quoted \\"value\\""'


def test_applescript_list_quotes_values():
    assert ssh_ticket.applescript_list(["30m", 'quoted "value"']) == (
        '{"30m", "quoted \\"value\\""}'
    )


def test_osascript_approval_prompt_activates_system_events():
    script = ssh_ticket.osascript_approval_script("Approve?")
    assert 'tell application "System Events"' in script
    assert "activate" in script
    assert "display dialog" in script


def test_osascript_ttl_selector_uses_standard_ok_cancel_list():
    script = ssh_ticket.osascript_ttl_selector_script(
        "Approve?", ["30m", "1h", "Custom..."], "30m"
    )
    assert 'tell application "System Events"' in script
    assert "activate" in script
    assert "choose from list" in script
    assert "OK button name" not in script
    assert "cancel button name" not in script
    assert "Custom..." in script


def test_osascript_ttl_text_prompt_uses_approve_default_button():
    script = ssh_ticket.osascript_ttl_text_prompt_script("Approve?", "30m")
    assert 'tell application "System Events"' in script
    assert "activate" in script
    assert "display dialog" in script
    assert 'default answer "30m"' in script
    assert 'default button "Approve"' in script


def test_ttl_choices_include_common_values_allowed_by_max():
    assert [
        ssh_ticket.format_duration(ttl) for ttl in ssh_ticket.ttl_choices(1800, 7200)
    ] == [
        "30m",
        "1h",
        "2h",
    ]
    assert [
        ssh_ticket.format_duration(ttl) for ttl in ssh_ticket.ttl_choices(1800, 43200)
    ] == [
        "30m",
        "1h",
        "2h",
        "12h",
    ]


def test_ttl_choices_include_nonstandard_default():
    assert [
        ssh_ticket.format_duration(ttl) for ttl in ssh_ticket.ttl_choices(2700, 7200)
    ] == [
        "30m",
        "45m",
        "1h",
        "2h",
    ]


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
        ["ensure", "--quiet", "--gui", "--cert-alias", "org", "org"]
    )

    assert args.func == ssh_ticket.cmd_ensure
    assert args.quiet
    assert args.gui
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
