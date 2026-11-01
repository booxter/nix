from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import httpx2
import pytest
from pydantic import AnyHttpUrl
from vikunja_provision.api import HttpVikunja
from vikunja_provision.cli import run
from vikunja_provision.models import Bot, Declaration, Declarations, ProvisionError, Share
from vikunja_provision.storage import FileCredentials
from vikunja_provision.workflow import apply, plan

from .fakes import MemoryTokenStore, seat_targets
from .server import SESSION, BrowserPrompt, InterruptedPrompt, UnusedPrompt, running_server


def write_declarations(path: Path, desired: Declaration) -> None:
    declarations = Declarations({"org": {"agents": desired}})
    path.write_text(declarations.model_dump_json(), encoding="utf-8")


def test_http_reconciliation_and_rotation_with_paginated_lists(
    declaration: Declaration, tmp_path: Path
) -> None:
    store = FileCredentials(tmp_path / "credentials.json")
    with running_server() as server, httpx2.Client() as client:
        server.backend.bot_records = [
            Bot(id=1, username="bot-other", name="Other", status=0),
            Bot(id=2, username="bot-agents", name="Old name", status=2),
        ]
        server.backend.project_shares[10] = [
            Share(username="human", permission=2),
            Share(username="bot-agents", permission=0),
        ]
        server.backend.issue_token(1, declaration.token)
        server.backend.issue_token(2, declaration.token.model_copy(update={"title": "unrelated"}))
        desired = declaration.model_copy(update={"server": AnyHttpUrl(server.url)})
        api = HttpVikunja(client, server.url, SESSION)

        prepared = plan(desired, api, store, rotate_token=False, now=datetime.now(UTC))
        apply(desired, prepared, api, store)
        apply(
            desired,
            plan(desired, api, store, rotate_token=True, now=datetime.now(UTC)),
            api,
            store,
        )

        assert plan(desired, api, store, rotate_token=False, now=datetime.now(UTC)).changes == []
        assert api.bots()[1].name == "Coding agents"
        assert api.bots()[1].status == 0
        assert Share(username="bot-agents", permission=1) in api.shares(10)
        assert len(api.tokens(2)) == 2
        assert len(api.tokens(1)) == 1


@pytest.mark.parametrize("status", [302, 401, 403, 500])
def test_http_errors_are_sanitized_and_redirects_are_not_followed(status: int) -> None:
    with running_server() as server, httpx2.Client() as client:
        server.status = status
        api = HttpVikunja(client, server.url, SESSION)

        with pytest.raises(ProvisionError, match=f"HTTP {status}") as error:
            api.bots()

        assert "user-session-secret" not in str(error.value)


@pytest.mark.parametrize("failure", ["malformed", "wrong_page", "empty_page"])
def test_invalid_responses_fail_without_leaking_content(failure: str) -> None:
    with running_server() as server, httpx2.Client() as client:
        setattr(server, failure, True)
        api = HttpVikunja(client, server.url, SESSION)

        with pytest.raises(ProvisionError) as error:
            api.bots()

        assert "tk_secret_response" not in str(error.value)


def test_connection_failure_is_actionable() -> None:
    with running_server() as server:
        url = server.url

    with httpx2.Client() as client, pytest.raises(ProvisionError, match="Could not reach"):
        HttpVikunja(client, url, SESSION).bots()


def test_cli_sso_plan_apply_and_repeat(
    declaration: Declaration, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config_path = tmp_path / "declarations.json"
    credentials_path = tmp_path / "credentials.json"
    with running_server() as server:
        desired = declaration.model_copy(update={"server": AnyHttpUrl(server.url)})
        write_declarations(config_path, desired)
        options = [
            "org",
            "agents",
            "--declarations-file",
            str(config_path),
            "--credentials-file",
            str(credentials_path),
        ]

        assert run(["plan", *options], prompt=BrowserPrompt()) == 0
        assert server.backend.bots() == []
        assert not credentials_path.exists()
        assert run(["apply", *options], prompt=BrowserPrompt()) == 0
        assert run(["apply", *options], prompt=BrowserPrompt()) == 0

    assert credentials_path.stat().st_mode & 0o777 == 0o600
    assert FileCredentials(credentials_path).load() is not None
    output = capsys.readouterr()
    assert "create bot bot-agents" in output.out
    assert '"changes": []' in output.out
    assert "secret" not in output.out + output.err


def test_cli_can_use_a_private_session_file(
    declaration: Declaration, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    session_path = tmp_path / "session"
    session_path.write_text(SESSION.get_secret_value(), encoding="utf-8")
    session_path.chmod(0o600)
    config_path = tmp_path / "declarations.json"
    with running_server() as server:
        write_declarations(
            config_path, declaration.model_copy(update={"server": AnyHttpUrl(server.url)})
        )
        result = run(
            [
                "apply",
                "org",
                "agents",
                "--declarations-file",
                str(config_path),
                "--credentials-file",
                str(tmp_path / "credentials.json"),
                "--session-token-file",
                str(session_path),
            ],
            prompt=UnusedPrompt(),
        )

    assert result == 0
    assert "secret" not in capsys.readouterr().out


def test_cli_reports_invalid_declarations_and_missing_files(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "declarations.json"
    options = [
        "plan",
        "org",
        "agents",
        "--declarations-file",
        str(path),
        "--credentials-file",
        str(tmp_path / "credentials"),
    ]
    assert run(options) == 1
    path.write_text('{"org":{"agents":{"server":"https://example.test"}}}', encoding="utf-8")
    assert run(options) == 1
    assert "Invalid declaration" in capsys.readouterr().err


def test_cli_handles_interrupted_sso(declaration: Declaration, tmp_path: Path) -> None:
    path = tmp_path / "declarations.json"
    write_declarations(path, declaration)
    assert (
        run(
            [
                "plan",
                "org",
                "agents",
                "--declarations-file",
                str(path),
                "--credentials-file",
                str(tmp_path / "credentials"),
            ],
            prompt=InterruptedPrompt(),
        )
        == 130
    )


@pytest.mark.parametrize("host,bot", [("missing", "agents"), ("org", "missing")])
def test_cli_rejects_unknown_targets_before_login(
    declaration: Declaration,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    host: str,
    bot: str,
) -> None:
    path = tmp_path / "declarations.json"
    write_declarations(path, declaration)
    assert (
        run(
            [
                "plan",
                host,
                bot,
                "--declarations-file",
                str(path),
                "--credentials-file",
                str(tmp_path / "credentials"),
            ],
            prompt=UnusedPrompt(),
        )
        == 1
    )
    assert "No Vikunja bot declaration" in capsys.readouterr().err


def test_cli_plans_and_distributes_to_declared_seats(
    declaration: Declaration, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declaration.seats = seat_targets()
    token_store = MemoryTokenStore()
    path = tmp_path / "declarations.json"
    credentials = tmp_path / "credentials.json"
    with running_server() as server:
        declaration.server = AnyHttpUrl(server.url)
        write_declarations(path, declaration)
        options = [
            "org",
            "agents",
            "--declarations-file",
            str(path),
            "--credentials-file",
            str(credentials),
        ]
        assert run(["plan", *options], prompt=BrowserPrompt(), token_store=token_store) == 0
        assert token_store.values == {}
        assert not credentials.exists()
        assert server.backend.bots() == []
        assert run(["apply", *options], prompt=BrowserPrompt(), token_store=token_store) == 0
        assert run(["apply", *options], prompt=BrowserPrompt(), token_store=token_store) == 0
        assert len(server.backend.tokens(1)) == 1

    assert set(token_store.values) == {"frame", "mair", "mmini"}
    assert all(
        value.get_secret_value() == "Bearer tk_secret_1" for value in token_store.values.values()
    )
    output = capsys.readouterr()
    assert "update SOPS secret mair:" in output.out
    assert "tk_secret_1" not in output.out + output.err


def test_cli_sops_preflight_failure_prevents_provisioning(
    declaration: Declaration, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declaration.seats = seat_targets()
    token_store = MemoryTokenStore(failing_reads={"mair"})
    path = tmp_path / "declarations.json"
    credentials = tmp_path / "credentials.json"
    with running_server() as server:
        declaration.server = AnyHttpUrl(server.url)
        write_declarations(path, declaration)
        assert (
            run(
                [
                    "apply",
                    "org",
                    "agents",
                    "--declarations-file",
                    str(path),
                    "--credentials-file",
                    str(credentials),
                ],
                prompt=BrowserPrompt(),
                token_store=token_store,
            )
            == 1
        )
        assert server.backend.bots() == []
        assert server.backend.tokens(1) == []

    assert not credentials.exists()
    assert token_store.values == {}
    assert "Could not read SOPS" in capsys.readouterr().err
