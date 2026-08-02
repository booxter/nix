from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

from .errors import ToolError
from .model import KeyPath
from .process import ProcessRunner
from .repository import SecretRepository
from .secrets import SopsBackend

LoginUser = Literal["root", "ihrachyshka", "both"]


class PasswordStore(Protocol):
    def insert(self, entry: str) -> None: ...

    def generate(self, entry: str, length: int) -> None: ...

    def read(self, entry: str) -> str: ...

    def write(self, entry: str, password: str) -> None: ...


class PasswordHasher(Protocol):
    def sha512(self, password: str) -> str: ...


@dataclass(frozen=True)
class CommandPasswordStore:
    runner: ProcessRunner

    def insert(self, entry: str) -> None:
        self.runner.run(["pass", "insert", entry], capture_output=False)

    def generate(self, entry: str, length: int) -> None:
        self.runner.run(["pass", "generate", "--force", entry, str(length)])

    def read(self, entry: str) -> str:
        lines = self.runner.run(["pass", "show", entry]).splitlines()
        return lines[0] if lines else ""

    def write(self, entry: str, password: str) -> None:
        self.runner.run(
            ["pass", "insert", "--multiline", "--force", entry],
            input_text=f"{password}\n",
        )


@dataclass(frozen=True)
class CommandPasswordHasher:
    runner: ProcessRunner

    def sha512(self, password: str) -> str:
        result = self.runner.run(
            ["mkpasswd", "--method=sha-512", "--stdin"],
            input_text=f"{password}\n",
        ).strip()
        if not result.startswith("$6$"):
            raise ToolError("mkpasswd returned an unexpected hash format.")
        return result


@dataclass(frozen=True)
class PasswordResult:
    secret: Path
    entries: tuple[str, ...]
    action: Literal["Generated", "Inserted"]
    user: LoginUser


@dataclass
class PasswordService:
    repository: SecretRepository
    sops: SopsBackend
    store: PasswordStore
    hasher: PasswordHasher

    def update(
        self,
        host: str,
        user: LoginUser,
        *,
        generate: bool,
        prefix: str = "host",
        length: int = 32,
    ) -> PasswordResult:
        secret = self.repository.secret(host)
        if not secret.is_file():
            raise ToolError(
                f"Secret not found for host {host}: {secret}\n"
                "Bootstrap it first with: nix run .#sops-bootstrap -- "
                f"--domain {self.repository.domain.name} {host}"
            )
        if length <= 0:
            raise ToolError("SOPS_PASS_GENERATE_LENGTH must be positive.")

        source_user = "root" if user == "both" else user
        entry = f"{prefix}/{host}/{source_user}"
        if generate:
            self.store.generate(entry, length)
            action: Literal["Generated", "Inserted"] = "Generated"
        else:
            self.store.insert(entry)
            action = "Inserted"

        password = self.store.read(entry)
        entries = [entry]
        if user == "both":
            extra_entry = f"{prefix}/{host}/ihrachyshka"
            self.store.write(extra_entry, password)
            entries.append(extra_entry)
        if not password:
            raise ToolError(f"Stored password must not be empty: {entry}")

        password_hash = self.hasher.sha512(password)
        users = ("root", "ihrachyshka") if user == "both" else (user,)
        for target in users:
            self.sops.set_value(
                secret,
                KeyPath.from_segments("users", target, "hashedPassword"),
                password_hash,
            )
        return PasswordResult(secret, tuple(entries), action, user)
