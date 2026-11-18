import pathlib
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass

import pytest
from git_hardware_signing_key import PublicKey, SystemCommands, run, select_key

DOCK = "sk-ssh-ed25519@openssh.com ZG9jaw== dock"
LAPTOP = "sk-ssh-ed25519@openssh.com bGFwdG9w laptop"
OTHER = "ssh-ed25519 b3RoZXI= other"
APPROVED = {PublicKey.parse(DOCK), PublicKey.parse(LAPTOP)}


@dataclass
class AgentCommands:
    keys: str
    selected: str = DOCK
    allow_local_selection: bool = True

    def output(self, arguments: Sequence[str]) -> str:
        if arguments == ["ssh-add", "-L"]:
            return self.keys
        if arguments == ["select-local"] and self.allow_local_selection:
            return self.selected
        raise AssertionError("Unexpected command or local selection in a forwarded session")


def test_local_selection_wins_over_agent_order_and_comments() -> None:
    commands = AgentCommands(LAPTOP + "\n" + DOCK.replace(" dock", " another comment"))
    assert select_key(APPROVED, commands, "select-local", False) == PublicKey.parse(DOCK)


def test_forwarded_session_uses_first_approved_agent_key() -> None:
    commands = AgentCommands(OTHER + "\n" + LAPTOP + "\n" + DOCK, allow_local_selection=False)
    assert select_key(APPROVED, commands, "select-local", True) == PublicKey.parse(LAPTOP)


def test_agent_only_backend() -> None:
    assert select_key(APPROVED, AgentCommands(DOCK), None, False) == PublicKey.parse(DOCK)


@pytest.mark.parametrize(
    ("keys", "selected"),
    [(LAPTOP, DOCK), (OTHER, OTHER), ("", DOCK)],
)
def test_no_fallback_when_selected_key_is_missing_or_unapproved(keys: str, selected: str) -> None:
    with pytest.raises(ValueError, match="No approved"):
        select_key(APPROVED, AgentCommands(keys, selected), "select-local", False)


@pytest.mark.parametrize("selected", ["", "invalid", DOCK + "\n" + LAPTOP])
def test_invalid_selector_output_is_rejected(selected: str) -> None:
    with pytest.raises(ValueError, match="Expected one"):
        select_key(APPROVED, AgentCommands(DOCK, selected), "select-local", False)


def test_empty_approval_list_rejects_agent_keys() -> None:
    with pytest.raises(ValueError, match="No approved"):
        select_key(set(), AgentCommands(DOCK), None, False)


def test_cli_success_and_errors(tmp_path: pathlib.Path, capsys: pytest.CaptureFixture[str]) -> None:
    approved = tmp_path / "approved"
    approved.write_text(DOCK + "\n\n")
    args = ["--approved-keys", str(approved)]
    assert run(args, AgentCommands(DOCK), forwarded=False) == 0
    assert capsys.readouterr().out == "key::sk-ssh-ed25519@openssh.com ZG9jaw==\n"
    assert run(args, AgentCommands(OTHER), forwarded=True) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert "No approved" in output.err
    approved.unlink()
    assert run(args, AgentCommands(DOCK), forwarded=False) == 1
    assert capsys.readouterr().out == ""


def test_command_output_and_failure() -> None:
    commands = SystemCommands()
    assert commands.output([sys.executable, "-c", "print('result')"]) == "result\n"
    with pytest.raises(subprocess.CalledProcessError):
        commands.output([sys.executable, "-c", "raise SystemExit(1)"])
