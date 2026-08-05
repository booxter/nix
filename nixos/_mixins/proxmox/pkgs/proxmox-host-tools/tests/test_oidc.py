from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

from proxmox_host_tools.oidc import load_config, run


def fixture_executable(tmp_path: Path) -> Path:
    source = Path(__file__).with_name("pveum_fixture.py").read_text()
    executable = tmp_path / "pveum"
    executable.write_text(f"#!{sys.executable}\n{source}")
    executable.chmod(0o755)
    return executable


def config_data(tmp_path: Path, executable: Path) -> dict[str, object]:
    return {
        "pveum": str(executable),
        "pmxcfs_directory": str(tmp_path / "pve"),
        "client_secret_file": str(tmp_path / "client-secret"),
        "realm": "sso",
        "issuer_url": "https://sso.example.test/oauth2/openid/proxmox",
        "client_id": "proxmox",
        "autocreate_users": True,
        "groups_claim": "proxmox_groups",
        "autocreate_groups": True,
        "overwrite_groups": True,
        "scopes": ["openid", "profile", "email", "groups"],
        "comment": "Kanidm SSO",
        "username_claim": "preferred_username",
        "mapped_group": "infra-admins-sso",
        "group_comment": "Kanidm infra-admins OIDC group",
        "acl_path": "/",
        "role": "Administrator",
    }


def write_config(
    tmp_path: Path,
    executable: Path,
    overrides: dict[str, object] | None = None,
) -> Path:
    path = tmp_path / "oidc.json"
    data = config_data(tmp_path, executable)
    data.update(overrides or {})
    path.write_text(json.dumps(data))
    return path


def invoke(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    invalid_list: bool = False,
    fail: bool = False,
    overrides: dict[str, object] | None = None,
) -> tuple[int, str, Path]:
    state = tmp_path / "pveum-state.json"
    executable = fixture_executable(tmp_path)
    (tmp_path / "pve").mkdir(exist_ok=True)
    (tmp_path / "client-secret").write_text("super-secret\n")
    monkeypatch.setenv("PVEUM_STATE", str(state))
    if invalid_list:
        monkeypatch.setenv("PVEUM_INVALID_LIST", "1")
    if fail:
        monkeypatch.setenv("PVEUM_FAIL", "1")
    stderr = io.StringIO()
    status = run(["--config", str(write_config(tmp_path, executable, overrides))], stderr)
    return status, stderr.getvalue(), state


def test_reconciles_realm_group_and_acl_without_command_transcripts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status, stderr, state_path = invoke(tmp_path, monkeypatch)

    assert status == 0
    assert stderr == ""
    initial = json.loads(state_path.read_text())
    assert initial["realms"]["sso"] == {
        "operation": "add",
        "--type": "openid",
        "--username-claim": "preferred_username",
        "--issuer-url": "https://sso.example.test/oauth2/openid/proxmox",
        "--client-id": "proxmox",
        "--client-key": "super-secret",
        "--autocreate": "1",
        "--groups-claim": "proxmox_groups",
        "--groups-autocreate": "1",
        "--groups-overwrite": "1",
        "--scopes": "openid profile email groups",
        "--comment": "Kanidm SSO",
    }
    assert initial["groups"] == {
        "infra-admins-sso": {"--comment": "Kanidm infra-admins OIDC group"}
    }
    assert initial["acls"] == {"/": {"-groups": "infra-admins-sso", "-roles": "Administrator"}}

    status, stderr, _ = invoke(tmp_path, monkeypatch)

    assert status == 0
    assert stderr == ""
    reconciled = json.loads(state_path.read_text())
    assert reconciled["realms"]["sso"]["operation"] == "modify"
    assert reconciled["groups"] == initial["groups"]
    assert reconciled["acls"] == initial["acls"]


def test_invalid_pveum_json_is_reported_before_mutation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status, stderr, state = invoke(tmp_path, monkeypatch, invalid_list=True)

    assert status == 1
    assert "invalid pveum realm list" in stderr
    assert not state.exists()


def test_pveum_failure_does_not_expose_client_secret(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status, stderr, state = invoke(tmp_path, monkeypatch, fail=True)

    assert status == 1
    assert "fixture failure" in stderr
    assert "super-secret" not in stderr
    assert not state.exists()


def test_missing_secret_fails_before_contacting_pveum(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable = fixture_executable(tmp_path)
    (tmp_path / "pve").mkdir()
    state = tmp_path / "pveum-state.json"
    monkeypatch.setenv("PVEUM_STATE", str(state))
    stderr = io.StringIO()

    status = run(["--config", str(write_config(tmp_path, executable))], stderr)

    assert status == 1
    assert "failed to read" in stderr.getvalue()
    assert not state.exists()


def test_configuration_rejects_unknown_fields(tmp_path: Path) -> None:
    data = config_data(tmp_path, tmp_path / "pveum")
    data["unused_feature"] = True
    path = tmp_path / "invalid.json"
    path.write_text(json.dumps(data))

    with pytest.raises(RuntimeError, match="failed to load"):
        load_config(path)


def test_false_boolean_values_are_sent_in_proxmox_binary_form(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status, stderr, state_path = invoke(
        tmp_path,
        monkeypatch,
        overrides={
            "autocreate_users": False,
            "autocreate_groups": False,
            "overwrite_groups": False,
        },
    )

    assert status == 0
    assert stderr == ""
    realm = json.loads(state_path.read_text())["realms"]["sso"]
    assert realm["--autocreate"] == "0"
    assert realm["--groups-autocreate"] == "0"
    assert realm["--groups-overwrite"] == "0"
