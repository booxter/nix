import argparse
import json
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import NoReturn, Protocol, TextIO, cast


JsonObject = dict[str, object]


class CodexMcpError(Exception):
    """Expected error that should be presented without a traceback."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str], *, capture_output: bool) -> CommandResult: ...


class SystemCommandRunner:
    def run(self, arguments: Sequence[str], *, capture_output: bool) -> CommandResult:
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=capture_output,
            text=True,
        )
        return CommandResult(completed.returncode, completed.stdout or "", completed.stderr or "")


class McpClient(Protocol):
    def enabled_http_servers(self) -> tuple[str, ...]: ...

    def login(self, name: str) -> int: ...


def _decode_object_list(text: str) -> list[JsonObject]:
    try:
        value: object = json.loads(text)
    except json.JSONDecodeError as error:
        raise CodexMcpError(f"Invalid JSON from codex mcp list: {error.msg}") from error
    if not isinstance(value, list) or not all(
        isinstance(item, dict) and all(isinstance(key, str) for key in item) for item in value
    ):
        raise CodexMcpError("Expected a JSON object list from codex mcp list")
    return cast(list[JsonObject], value)


def _object_value(source: Mapping[str, object], key: str) -> JsonObject | None:
    value = source.get(key)
    if not isinstance(value, dict) or not all(isinstance(item, str) for item in value):
        return None
    return cast(JsonObject, value)


class CodexCliMcpClient:
    def __init__(self, runner: CommandRunner) -> None:
        self.runner = runner

    def enabled_http_servers(self) -> tuple[str, ...]:
        # Codex documents its MCP CLI as the configuration and OAuth boundary;
        # the OpenAI Python SDK does not manage local Codex MCP sessions.
        result = self.runner.run(["codex", "mcp", "list", "--json"], capture_output=True)
        if result.returncode != 0:
            detail = result.stderr.strip()
            suffix = f": {detail}" if detail else ""
            raise CodexMcpError(f"codex mcp list failed{suffix}")

        names: list[str] = []
        for server in _decode_object_list(result.stdout):
            name = server.get("name")
            enabled = server.get("enabled")
            transport = _object_value(server, "transport")
            transport_type = None if transport is None else transport.get("type")
            if (
                not isinstance(name, str)
                or not isinstance(enabled, bool)
                or not isinstance(transport_type, str)
            ):
                raise CodexMcpError("Invalid MCP server entry from codex mcp list")
            if enabled and transport_type == "streamable_http":
                names.append(name)
        return tuple(names)

    def login(self, name: str) -> int:
        return self.runner.run(["codex", "mcp", "login", name], capture_output=False).returncode


def _print_options(client: McpClient, output: TextIO) -> None:
    print("\nEnabled HTTP MCPs:", file=output)
    try:
        names = client.enabled_http_servers()
    except CodexMcpError:
        print("  (unable to read Codex MCP configuration)", file=output)
        return
    if not names:
        print("  (none)", file=output)
        return
    for name in names:
        print(f"  {name}", file=output)


class McpArgumentParser(argparse.ArgumentParser):
    def __init__(self, client: McpClient, *, stdout: TextIO, stderr: TextIO) -> None:
        super().__init__(
            prog="codex-mcp-init",
            description=(
                "Authenticate one MCP server or every enabled HTTP MCP server in list order."
            ),
        )
        self.client = client
        self.stdout = stdout
        self.stderr = stderr

    def print_help(self, file: object | None = None) -> None:
        output = self.stdout if file is None else cast(TextIO, file)
        super().print_help(output)
        _print_options(self.client, output)

    def error(self, message: str) -> NoReturn:
        self.print_usage(self.stderr)
        print(f"{self.prog}: error: {message}", file=self.stderr)
        _print_options(self.client, self.stderr)
        self.exit(2)


def _parser(client: McpClient, *, stdout: TextIO, stderr: TextIO) -> McpArgumentParser:
    parser = McpArgumentParser(client, stdout=stdout, stderr=stderr)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument(
        "mcp_name",
        metavar="mcp-name",
        nargs="?",
        help="authenticate one MCP server by name",
    )
    target.add_argument(
        "--all",
        dest="all_servers",
        action="store_true",
        help="authenticate every enabled HTTP MCP server",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    client: McpClient | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    arguments = tuple(sys.argv[1:] if argv is None else argv)
    mcp_client = client or CodexCliMcpClient(SystemCommandRunner())
    try:
        parsed = _parser(mcp_client, stdout=stdout, stderr=stderr).parse_args(arguments)
    except SystemExit as error:
        return error.code if isinstance(error.code, int) else 1

    all_servers = cast(bool, parsed.all_servers)
    mcp_name = cast(str | None, parsed.mcp_name)
    if all_servers:
        try:
            names = mcp_client.enabled_http_servers()
        except CodexMcpError as error:
            print(error, file=stderr)
            return 1
    else:
        assert mcp_name is not None
        names = (mcp_name,)
    if not names:
        print("No enabled HTTP MCP servers found.", file=stderr)
        return 1

    for name in names:
        print(f"Initializing MCP {name}...", file=stdout)
        status = mcp_client.login(name)
        if status != 0:
            return status
    return 0
