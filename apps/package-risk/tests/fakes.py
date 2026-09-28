from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from package_risk.process import CommandResult


@dataclass(frozen=True)
class Call:
    arguments: tuple[str, ...]
    stdin: str | None
    accepted_codes: tuple[int, ...]
    environment: dict[str, str] | None


@dataclass
class FakeRunner:
    responses: list[CommandResult]
    calls: list[Call] = field(default_factory=list)
    metadata_requests: list[dict[str, object]] = field(default_factory=list)

    def run(
        self,
        arguments: tuple[str, ...],
        *,
        stdin: str | None = None,
        accepted_codes: tuple[int, ...] = (0,),
        environment: dict[str, str] | None = None,
    ) -> CommandResult:
        self.calls.append(Call(arguments, stdin, accepted_codes, environment))
        if environment and "PACKAGE_RISK_REQUEST_PATH" in environment:
            text = Path(environment["PACKAGE_RISK_REQUEST_PATH"]).read_text()
            value = json.loads(text)
            assert isinstance(value, dict)
            self.metadata_requests.append(value)
        return self.responses.pop(0)


def result(stdout: str, returncode: int = 0) -> CommandResult:
    return CommandResult(stdout=stdout, returncode=returncode)
