import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from gh_restart_failed_jobs.errors import RestartError


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str]) -> CommandResult: ...


@dataclass(frozen=True)
class SubprocessRunner:
    def run(self, arguments: Sequence[str]) -> CommandResult:
        result = subprocess.run(arguments, check=False, capture_output=True, text=True)
        return CommandResult(result.returncode, result.stdout, result.stderr)


class TokenProvider(Protocol):
    def token(self, host: str) -> str: ...


@dataclass(frozen=True)
class GhTokenProvider:
    environ: Mapping[str, str]
    runner: CommandRunner
    executable: str = "gh"

    def token(self, host: str) -> str:
        variables = (
            ("GH_TOKEN", "GITHUB_TOKEN")
            if host == "github.com"
            else ("GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")
        )
        for variable in variables:
            token = self.environ.get(variable, "").strip()
            if token:
                return token

        result = self.runner.run((self.executable, "auth", "token", "--hostname", host))
        token = result.stdout.strip()
        if result.returncode != 0 or not token:
            detail = result.stderr.strip() or "gh returned no token"
            raise RestartError(f"cannot obtain GitHub token for {host}: {detail}")
        return token
