import io
import json
from collections.abc import Sequence

import pytest

from codex_mcp_init.cli import (
    CodexCliMcpClient,
    CodexMcpError,
    CommandResult,
    main,
)


class FakeCommandRunner:
    def __init__(self, results: Sequence[CommandResult]) -> None:
        self.results = list(results)
        self.calls: list[tuple[tuple[str, ...], bool]] = []

    def run(self, arguments: Sequence[str], *, capture_output: bool) -> CommandResult:
        self.calls.append((tuple(arguments), capture_output))
        if not self.results:
            raise AssertionError(f"unexpected command: {arguments}")
        return self.results.pop(0)


class FakeMcpClient:
    def __init__(
        self,
        names: Sequence[str] = (),
        *,
        list_error: CodexMcpError | None = None,
        login_statuses: Sequence[int] = (),
    ) -> None:
        self.names = tuple(names)
        self.list_error = list_error
        self.login_statuses = list(login_statuses)
        self.logins: list[str] = []

    def enabled_http_servers(self) -> tuple[str, ...]:
        if self.list_error is not None:
            raise self.list_error
        return self.names

    def login(self, name: str) -> int:
        self.logins.append(name)
        return self.login_statuses.pop(0) if self.login_statuses else 0


def invoke(arguments: Sequence[str], client: FakeMcpClient) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = main(arguments, client=client, stdout=stdout, stderr=stderr)
    return status, stdout.getvalue(), stderr.getvalue()


def test_codex_cli_filters_enabled_http_servers_in_list_order() -> None:
    runner = FakeCommandRunner(
        [
            CommandResult(
                0,
                json.dumps(
                    [
                        {"name": "local", "enabled": True, "transport": {"type": "stdio"}},
                        {
                            "name": "disabled",
                            "enabled": False,
                            "transport": {"type": "streamable_http"},
                        },
                        {
                            "name": "calendar",
                            "enabled": True,
                            "transport": {"type": "streamable_http"},
                        },
                        {
                            "name": "github",
                            "enabled": True,
                            "transport": {"type": "streamable_http"},
                        },
                    ]
                ),
            ),
            CommandResult(0),
        ]
    )
    client = CodexCliMcpClient(runner)

    assert client.enabled_http_servers() == ("calendar", "github")
    assert client.login("calendar") == 0
    assert runner.calls == [
        (("codex", "mcp", "list", "--json"), True),
        (("codex", "mcp", "login", "calendar"), False),
    ]


@pytest.mark.parametrize(
    ("result", "message"),
    [
        (CommandResult(1, stderr="configuration error"), "configuration error"),
        (CommandResult(0, "not json"), "Invalid JSON"),
        (CommandResult(0, "{}"), "Expected a JSON object list"),
        (CommandResult(0, '[{"name":"broken"}]'), "Invalid MCP server entry"),
    ],
)
def test_codex_cli_reports_list_failures(result: CommandResult, message: str) -> None:
    client = CodexCliMcpClient(FakeCommandRunner([result]))

    with pytest.raises(CodexMcpError, match=message):
        client.enabled_http_servers()


def test_initializes_all_enabled_servers_and_stops_on_failure() -> None:
    client = FakeMcpClient(("calendar", "github", "gmail"), login_statuses=(0, 9, 0))

    status, stdout, stderr = invoke(["--all"], client)

    assert status == 9
    assert stderr == ""
    assert client.logins == ["calendar", "github"]
    assert stdout == "Initializing MCP calendar...\nInitializing MCP github...\n"


def test_initializes_one_named_server_without_listing() -> None:
    client = FakeMcpClient(list_error=CodexMcpError("must not list"))

    status, stdout, stderr = invoke(["calendar"], client)

    assert status == 0
    assert stderr == ""
    assert stdout == "Initializing MCP calendar...\n"
    assert client.logins == ["calendar"]


def test_help_and_missing_argument_show_available_servers() -> None:
    client = FakeMcpClient(("calendar", "github"))

    help_status, help_stdout, _ = invoke(["--help"], client)
    missing_status, _, missing_stderr = invoke([], client)

    assert help_status == 0
    assert "Authenticate one MCP server" in help_stdout
    assert "  calendar\n  github\n" in help_stdout
    assert missing_status == 2
    assert "Enabled HTTP MCPs:" in missing_stderr


def test_reports_no_servers_and_configuration_errors() -> None:
    empty_status, _, empty_stderr = invoke(["--all"], FakeMcpClient())
    error_status, _, error_stderr = invoke(
        ["--all"],
        FakeMcpClient(list_error=CodexMcpError("cannot list")),
    )

    assert empty_status == 1
    assert "No enabled HTTP MCP servers found" in empty_stderr
    assert error_status == 1
    assert "cannot list" in error_stderr


@pytest.mark.parametrize(
    "arguments",
    [["--unknown"], ["one", "two"], ["--all", "one"]],
)
def test_rejects_invalid_arguments(arguments: list[str]) -> None:
    status, _, stderr = invoke(arguments, FakeMcpClient())

    assert status == 2
    assert "usage: codex-mcp-init" in stderr
