import importlib.util
import pathlib
import time
import types

import pytest


MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[1] / "pkgs" / "ssh-ticket" / "main.py"
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


def test_osascript_ttl_selector_activates_system_events():
    script = ssh_ticket.osascript_ttl_selector_script("Approve?", ["30m", "1h"], "30m")
    assert 'tell application "System Events"' in script
    assert "activate" in script
    assert "choose from list" in script


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


def test_target_expression_includes_nixos_and_darwin_configs(tmp_path):
    expr = ssh_ticket.nix_targets_expr(tmp_path)
    assert 'render "nixos") f.nixosConfigurations' in expr
    assert 'render "darwin") f.darwinConfigurations' in expr


def test_resolve_target_accepts_unique_alias():
    targets = [
        {
            "name": "prox-srvarrvm",
            "enabled": True,
            "aliases": ["prox-srvarrvm", "srvarr"],
            "principal": "ihrachyshka@prox-srvarrvm",
            "sshHost": "prox-srvarrvm",
        }
    ]
    assert ssh_ticket.resolve_target(targets, "srvarr")["name"] == "prox-srvarrvm"


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
            "name": "local-beastvm",
            "enabled": True,
            "aliases": ["beast-alias"],
            "principal": "ihrachyshka@beast",
            "sshHost": "local-beastvm",
        },
    ]
    with pytest.raises(ssh_ticket.Error):
        ssh_ticket.resolve_target(targets, "beast-alias")


def test_existing_ticket_valid_uses_metadata(tmp_path):
    target = {
        "name": "prox-srvarrvm",
        "principal": "ihrachyshka@prox-srvarrvm",
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
    paths = ssh_ticket.target_paths({"name": "prox-orgvm"}, tmp_path)
    paths["public"].write_text("public\n", encoding="utf-8")
    paths["cert"].write_text("cert\n", encoding="utf-8")
    paths["metadata"].write_text('{"target":"prox-orgvm"}\n', encoding="utf-8")

    alias_paths = ssh_ticket.write_ticket_alias(paths, "org", tmp_path)

    assert alias_paths["public"].name == "org.pub"
    assert alias_paths["cert"].name == "org-cert.pub"
    assert alias_paths["cert"].read_text(encoding="utf-8") == "cert\n"
    assert alias_paths["metadata"].read_text(encoding="utf-8") == (
        '{"target":"prox-orgvm"}\n'
    )


def test_parser_has_ensure_command():
    args = ssh_ticket.build_parser().parse_args(
        ["ensure", "--quiet", "--gui", "--cert-alias", "org", "prox-orgvm"]
    )

    assert args.func == ssh_ticket.cmd_ensure
    assert args.quiet
    assert args.gui
    assert args.cert_alias == "org"
    assert args.target == "prox-orgvm"


def test_ssht_command_does_not_add_ticket_key_to_agent(tmp_path):
    cmd = ssh_ticket.ssht_ssh_command(
        types.SimpleNamespace(
            key=str(tmp_path / "id_ed25519"), ssh_args=["--", "true"]
        ),
        {"sshHost": "prox-srvarrvm"},
        {"cert": tmp_path / "id_ed25519-cert.pub"},
    )

    assert "AddKeysToAgent=no" in cmd
    assert cmd[-2:] == ["prox-srvarrvm", "true"]
