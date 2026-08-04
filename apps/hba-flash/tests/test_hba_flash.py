from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path


SCRIPT = Path(__file__).parent.parent / "hba-flash.sh"
REMOTE_DIRECTORY = re.compile(r"/tmp/hba-flash-[0-9-]+-[0-9]+")


def _write_command(directory: Path, name: str) -> None:
    command = directory / name
    command.symlink_to(Path(__file__).parent / "fake_command.py")


def _run(tmp_path: Path, *arguments: str) -> list[dict[str, str | list[str]]]:
    commands = tmp_path / "commands"
    commands.mkdir()
    for name in ("ssh", "scp"):
        _write_command(commands, name)
    log = tmp_path / "commands.jsonl"
    firmware = tmp_path / "firmware.bin"
    utility = tmp_path / "sas3flash"
    firmware.touch()
    utility.touch()
    environment = {
        **os.environ,
        "PATH": f"{commands}:{os.environ['PATH']}",
        "HBA_FLASH_TEST_LOG": str(log),
    }
    subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--sas3flash",
            str(utility),
            "--firmware",
            str(firmware),
            *arguments,
        ],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )
    return [json.loads(line) for line in log.read_text().splitlines()]


def _normalized(
    records: list[dict[str, str | list[str]]],
) -> list[dict[str, str | list[str]]]:
    return [
        {
            "command": record["command"],
            "arguments": [
                REMOTE_DIRECTORY.sub("REMOTE", argument)
                for argument in record["arguments"]
            ],
            "stdin": REMOTE_DIRECTORY.sub("REMOTE", str(record["stdin"])),
        }
        for record in records
    ]


def test_preflight_stages_checks_and_cleans_without_flashing(tmp_path: Path) -> None:
    records = _normalized(_run(tmp_path, "--host", "storage", "--controller", "2"))

    assert [(record["command"], record["arguments"]) for record in records] == [
        ("ssh", ["storage", "bash", "-s", "--", "2"]),
        ("ssh", ["storage", "mkdir -p 'REMOTE'"]),
        ("scp", ["-q", str(tmp_path / "sas3flash"), "storage:REMOTE/sas3flash"]),
        ("scp", ["-q", str(tmp_path / "firmware.bin"), "storage:REMOTE/firmware.bin"]),
        ("ssh", ["storage", "bash", "-s", "--", "REMOTE", "2"]),
        ("ssh", ["storage", "rm -rf 'REMOTE'"]),
    ]
    scripts = [str(record["stdin"]) for record in records]
    assert 'sudo "${tool}" -listall' in scripts[4]
    assert not any('cmd=(sudo "${tool}"' in script for script in scripts)


def test_flash_keeps_quiesce_flash_verify_and_reboot_order(tmp_path: Path) -> None:
    optionrom = tmp_path / "optionrom.rom"
    optionrom.touch()
    records = _normalized(
        _run(
            tmp_path,
            "--flash",
            "--reboot",
            "--optionrom",
            str(optionrom),
        )
    )

    command_names = [str(record["command"]) for record in records]
    assert command_names == ["ssh", "ssh", "scp", "scp", "scp", *(["ssh"] * 6)]
    scripts = [str(record["stdin"]) for record in records]
    assert "sudo systemctl stop jellyfin" in scripts[6]
    assert "md127 is still mounted" in scripts[7]
    assert 'cmd=(sudo "${tool}" -c "${controller}" -o -f "${firmware}")' in scripts[8]
    assert records[8]["arguments"][-1] == "1"
    assert records[9]["arguments"] == ["beast", "sudo systemctl reboot"]
    assert records[10]["arguments"] == ["beast", "rm -rf 'REMOTE'"]
