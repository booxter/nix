from __future__ import annotations

import os
import pwd
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


class Error(RuntimeError):
    pass


@dataclass(frozen=True)
class Launch:
    executable: Path
    arguments: tuple[str, ...]
    environment: Mapping[str, str]
    user: str | None = None
    working_directory: Path | None = None
    umask: int | None = None


class Executor(Protocol):
    def execute(self, launch: Launch) -> None: ...


class OsExecutor:
    # This process-replacing, privilege-dropping adapter is exercised on-host;
    # package tests cover the Launch passed to it.
    def execute(self, launch: Launch) -> None:  # pragma: no cover
        if launch.working_directory is not None:
            launch.working_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if launch.user is not None:
            if os.geteuid() != 0:
                raise Error("interactive authentication must run as root")
            try:
                account = pwd.getpwnam(launch.user)
            except KeyError as error:
                raise Error(f"unknown service user: {launch.user}") from error
            assert launch.working_directory is not None
            launch.working_directory.chmod(0o700)
            os.chown(launch.working_directory, account.pw_uid, account.pw_gid)
            os.initgroups(account.pw_name, account.pw_gid)
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
        if launch.working_directory is not None:
            os.chdir(launch.working_directory)
        if launch.umask is not None:
            os.umask(launch.umask)
        os.execve(launch.executable, launch.arguments, dict(launch.environment))


def launch(
    executable: Path,
    arguments: Sequence[str],
    environment: Mapping[str, str],
    executor: Executor,
    *,
    user: str | None = None,
    working_directory: Path | None = None,
    umask: int | None = None,
) -> None:
    executor.execute(
        Launch(
            executable=executable,
            arguments=(str(executable), *arguments),
            environment=environment,
            user=user,
            working_directory=working_directory,
            umask=umask,
        )
    )
