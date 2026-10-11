import re
import subprocess
from dataclasses import dataclass
from typing import Protocol

from nr.process import CommandRunner
from nr.review import ReviewRequest
from nr.tmux import Submission
from pydantic import ValidationError


class RemoteSubmitter(Protocol):
    def submit(self, host: str, request: ReviewRequest) -> Submission: ...


class RemoteAttacher(Protocol):
    def attach(self, host: str) -> int: ...


class SshAttacher:
    def attach(self, host: str) -> int:
        # Inherit the terminal rather than capturing SSH's interactive streams.
        # Quote the exact session target: zsh expands an unquoted =nr to the
        # executable's path when SSH passes this command to the login shell.
        return subprocess.run(
            ["ssh", "-a", "-t", "--", validate_host(host), "tmux attach -t '=nr'"], check=False
        ).returncode


def validate_host(host: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", host):
        raise ValueError("Remote host must be an SSH machine name")
    return host


def attach_command(host: str) -> str:
    return f"ssh -t {validate_host(host)} tmux attach -t nr"


@dataclass(frozen=True)
class SshSubmitter:
    runner: CommandRunner

    def submit(self, host: str, request: ReviewRequest) -> Submission:
        validate_host(host)
        # Only a fixed helper name crosses SSH's shell boundary. All review
        # choices travel as JSON over stdin; no laptop credentials are forwarded.
        result = self.runner.run(
            ["ssh", "-a", "-T", "--", host, "nr-submit"], input=request.model_dump_json()
        )
        if result.returncode:
            detail = result.stderr.strip() or f"SSH exited with status {result.returncode}"
            raise RuntimeError(
                f"Remote submission failed: {detail}\n"
                f"A job may already be running. Check before retrying: {attach_command(host)}"
            )
        try:
            return Submission.model_validate_json(result.stdout)
        except ValidationError as error:
            raise RuntimeError(
                "Remote submission was not acknowledged. "
                f"Check before retrying: {attach_command(host)}"
            ) from error
