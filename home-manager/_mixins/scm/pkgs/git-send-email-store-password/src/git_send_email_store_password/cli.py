import argparse
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol, TextIO


class StoreError(Exception):
    """The SMTP credential could not be stored safely."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str], *, input_text: str | None = None) -> CommandResult: ...


class SystemCommandRunner:
    def run(self, arguments: Sequence[str], *, input_text: str | None = None) -> CommandResult:
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            input=input_text,
            text=True,
        )
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)


@dataclass(frozen=True)
class SmtpConfiguration:
    server: str | None
    port: str | None
    user: str | None

    @property
    def host(self) -> str:
        if self.server is None:
            raise StoreError("sendemail.smtpServer is not configured.")
        if "\n" in self.server or "\r" in self.server:
            raise StoreError("sendemail.smtpServer must be a single line.")
        if self.port is not None and ("\n" in self.port or "\r" in self.port):
            raise StoreError("sendemail.smtpServerPort must be a single line.")
        return f"{self.server}:{self.port}" if self.port else self.server

    def require_user(self) -> str:
        if self.user is None:
            raise StoreError("sendemail.smtpUser is not configured.")
        if "\n" in self.user or "\r" in self.user:
            raise StoreError("sendemail.smtpUser must be a single line.")
        return self.user


@dataclass(frozen=True)
class SmtpCredential:
    host: str
    user: str
    password: str


class CredentialStore(Protocol):
    def configuration(self) -> SmtpConfiguration: ...

    def approve(self, credential: SmtpCredential) -> None: ...


class GitCredentialStore:
    def __init__(self, runner: CommandRunner) -> None:
        self.runner = runner

    def _configuration_value(self, name: str) -> str | None:
        result = self.runner.run(["git", "config", "--get", name])
        if result.returncode == 1:
            return None
        if result.returncode != 0:
            raise StoreError(f"git config failed while reading {name}")
        return result.stdout.rstrip("\n") or None

    def configuration(self) -> SmtpConfiguration:
        return SmtpConfiguration(
            server=self._configuration_value("sendemail.smtpserver"),
            port=self._configuration_value("sendemail.smtpserverport"),
            user=self._configuration_value("sendemail.smtpuser"),
        )

    def approve(self, credential: SmtpCredential) -> None:
        # Git owns the osxkeychain schema and helper selection. Using its
        # credential protocol keeps this compatible with git-send-email.
        request = (
            "protocol=smtp\n"
            f"host={credential.host}\n"
            f"username={credential.user}\n"
            f"password={credential.password}\n\n"
        )
        result = self.runner.run(
            [
                "git",
                "-c",
                "credential.helper=",
                "-c",
                "credential.helper=osxkeychain",
                "credential",
                "approve",
            ],
            input_text=request,
        )
        if result.returncode != 0:
            raise StoreError("Git could not store the SMTP credential in Keychain")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="git-send-email-store-password",
        add_help=False,
        description=(
            "Read an SMTP password from stdin and store it in macOS Keychain for the "
            "sendemail.smtpServer, sendemail.smtpServerPort, and sendemail.smtpUser values "
            "in the effective Git configuration."
        ),
    )
    parser.add_argument("-h", "--help", action="store_true")
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    stdin: TextIO = sys.stdin,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
    store: CredentialStore | None = None,
) -> int:
    parser = _parser()
    arguments, unexpected = parser.parse_known_args(argv)
    if arguments.help and not unexpected:
        parser.print_help(stdout)
        return 0
    if arguments.help or unexpected:
        parser.print_usage(stderr)
        return 1
    if stdin.isatty():
        print("Refusing to read an SMTP password from the terminal; pipe it on stdin.", file=stderr)
        return 1

    password = stdin.read().rstrip("\n")
    if not password:
        print("Refusing to store an empty SMTP password.", file=stderr)
        return 1
    if "\n" in password or "\r" in password:
        print("The SMTP password must be a single line.", file=stderr)
        return 1

    credential_store = store or GitCredentialStore(SystemCommandRunner())
    try:
        configuration = credential_store.configuration()
        credential = SmtpCredential(
            host=configuration.host,
            user=configuration.require_user(),
            password=password,
        )
        credential_store.approve(credential)
    except StoreError as error:
        print(error, file=stderr)
        return 1

    print(
        f"Stored the SMTP credential for {credential.user} at {credential.host} in Keychain.",
        file=stdout,
    )
    return 0
