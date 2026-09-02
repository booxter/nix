from __future__ import annotations

from collections.abc import Sequence
from io import StringIO

import pytest
from codex_mcp_login.cli import main
from codex_mcp_login.models import ServerStartup, StartupStatus


class ReadyProbe:
    def probe(self, server_names: Sequence[str]) -> tuple[ServerStartup, ...]:
        return tuple(ServerStartup(name, StartupStatus.READY) for name in server_names)


class UnexpectedLogin:
    def login(self, server_name: str) -> int:
        raise AssertionError(f"unexpected login for {server_name}")


class InterruptedProbe:
    def probe(self, server_names: Sequence[str]) -> tuple[ServerStartup, ...]:
        raise KeyboardInterrupt


def test_cli_runs_configured_servers() -> None:
    output = StringIO()

    status = main(
        ["--server", "alpha", "--server", "beta", "--timeout-seconds", "1"],
        probe=ReadyProbe(),
        login=UnexpectedLogin(),
        output=output,
    )

    assert status == 0
    assert "Checking 2 MCP server(s)" in output.getvalue()


@pytest.mark.parametrize("arguments", [[], ["--server", "alpha", "--timeout-seconds", "0"]])
def test_cli_rejects_invalid_arguments(arguments: list[str]) -> None:
    with pytest.raises(SystemExit, match="2"):
        main(arguments)


def test_cli_reports_interruption() -> None:
    output = StringIO()

    status = main(
        ["--server", "alpha"],
        probe=InterruptedProbe(),
        login=UnexpectedLogin(),
        output=output,
    )

    assert status == 130
    assert output.getvalue().endswith("interrupted\n")
