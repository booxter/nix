import importlib.util
import pathlib
import time

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
