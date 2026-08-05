from __future__ import annotations

import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass

from pydantic import TypeAdapter, ValidationError
from sops_tools.errors import CommandError, ToolError
from sops_tools.process import ProcessRunner, SubprocessRunner

from .models import PveUser, PveUserList, RemoteTokenRequest, TokenResponse


_USERS: TypeAdapter[list[PveUser] | PveUserList] = TypeAdapter(list[PveUser] | PveUserList)


@dataclass(frozen=True)
class PveumClient:
    runner: ProcessRunner
    privilege: tuple[str, ...]

    def issue(
        self,
        *,
        user: str,
        token_name: str,
        role: str,
        acl_path: str,
        replace: bool,
        comment: str,
    ) -> str:
        users = self._users()
        if user not in {item.userid for item in users}:
            self._run("user", "add", user, "--comment", comment)
        self._run("aclmod", acl_path, "-user", user, "-role", role)
        if replace:
            try:
                self._run("user", "token", "remove", user, token_name)
            except CommandError:
                pass
        output = self._run(
            "user",
            "token",
            "add",
            user,
            token_name,
            "--privsep",
            "0",
            "--output-format",
            "json",
        )
        try:
            return TokenResponse.model_validate_json(output).token_value()
        except (ValidationError, ValueError) as error:
            raise ToolError(f"invalid pveum token response: {error}") from error

    def _users(self) -> list[PveUser]:
        output = self._run("user", "list", "--output-format", "json")
        try:
            parsed = _USERS.validate_json(output)
        except ValidationError as error:
            raise ToolError(f"invalid pveum user list: {error}") from error
        return parsed if isinstance(parsed, list) else parsed.data

    def _run(self, *arguments: str) -> str:
        return self.runner.run([*self.privilege, "pveum", *arguments])


def main(argv: Sequence[str] | None = None) -> int:
    if argv:
        raise SystemExit("remote helper accepts its request on stdin")
    try:
        request = RemoteTokenRequest.model_validate_json(sys.stdin.read())
    except ValidationError as error:
        raise SystemExit(f"invalid remote token request: {error}") from error
    privilege = () if os.geteuid() == 0 else ("sudo", "-n")
    try:
        value = PveumClient(SubprocessRunner(), privilege).issue(
            user=request.user,
            token_name=request.token_name,
            role=request.role,
            acl_path=request.acl_path,
            replace=request.replace,
            comment=request.comment,
        )
    except ToolError as error:
        raise SystemExit(str(error)) from error
    print(value)
    return 0
