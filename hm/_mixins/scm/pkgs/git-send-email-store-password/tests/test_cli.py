import io
from collections.abc import Sequence

import pytest

from git_send_email_store_password.cli import (
    CommandResult,
    GitCredentialStore,
    SmtpConfiguration,
    SmtpCredential,
    StoreError,
    main,
)


class RecordingCredentialStore:
    def __init__(self, configuration: SmtpConfiguration) -> None:
        self.smtp_configuration = configuration
        self.credential: SmtpCredential | None = None

    def configuration(self) -> SmtpConfiguration:
        return self.smtp_configuration

    def approve(self, credential: SmtpCredential) -> None:
        self.credential = credential


class FakeCommandRunner:
    def __init__(self, results: Sequence[CommandResult]) -> None:
        self.results = list(results)
        self.calls: list[tuple[tuple[str, ...], str | None]] = []

    def run(self, arguments: Sequence[str], *, input_text: str | None = None) -> CommandResult:
        self.calls.append((tuple(arguments), input_text))
        if not self.results:
            raise AssertionError(f"unexpected command: {arguments}")
        return self.results.pop(0)


class TerminalInput(io.StringIO):
    def isatty(self) -> bool:
        return True


def invoke(
    password: str,
    *,
    store: RecordingCredentialStore,
    arguments: Sequence[str] = (),
    stdin: io.StringIO | None = None,
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = main(
        arguments,
        stdin=stdin or io.StringIO(password),
        stdout=stdout,
        stderr=stderr,
        store=store,
    )
    return status, stdout.getvalue(), stderr.getvalue()


def configured_store(*, port: str | None = "587") -> RecordingCredentialStore:
    return RecordingCredentialStore(SmtpConfiguration("smtp.example.com", port, "user@example.com"))


def test_describes_the_stdin_and_git_configuration_interface() -> None:
    status, stdout, stderr = invoke("", store=configured_store(), arguments=["--help"])

    assert status == 0
    assert stderr == ""
    assert "Read an SMTP password from stdin" in stdout
    assert "sendemail.smtpServerPort" in stdout


@pytest.mark.parametrize(
    ("port", "expected_host"),
    [("587", "smtp.example.com:587"), (None, "smtp.example.com")],
)
def test_stores_the_configured_credential(port: str | None, expected_host: str) -> None:
    store = configured_store(port=port)

    status, stdout, stderr = invoke("app-password\n", store=store)

    assert status == 0
    assert stderr == ""
    assert store.credential == SmtpCredential(expected_host, "user@example.com", "app-password")
    assert stdout == (
        f"Stored the SMTP credential for user@example.com at {expected_host} in Keychain.\n"
    )
    assert "app-password" not in stdout


@pytest.mark.parametrize(
    ("password", "message"),
    [
        ("", "Refusing to store an empty SMTP password."),
        ("\n\n", "Refusing to store an empty SMTP password."),
        ("first\nsecond\n", "The SMTP password must be a single line."),
        ("password\r\n", "The SMTP password must be a single line."),
    ],
)
def test_rejects_invalid_passwords(password: str, message: str) -> None:
    store = configured_store()

    status, stdout, stderr = invoke(password, store=store)

    assert status == 1
    assert stdout == ""
    assert stderr.strip() == message
    assert store.credential is None


def test_rejects_terminal_input_and_unexpected_arguments() -> None:
    store = configured_store()

    terminal_status, _, terminal_stderr = invoke(
        "password",
        store=store,
        stdin=TerminalInput("password"),
    )
    argument_status, _, argument_stderr = invoke(
        "password",
        store=store,
        arguments=["unexpected"],
    )

    assert terminal_status == 1
    assert "Refusing to read an SMTP password from the terminal" in terminal_stderr
    assert argument_status == 1
    assert "usage:" in argument_stderr


@pytest.mark.parametrize(
    ("configuration", "message"),
    [
        (SmtpConfiguration(None, "587", "user@example.com"), "smtpServer is not configured"),
        (SmtpConfiguration("smtp.example.com", "587", None), "smtpUser is not configured"),
        (
            SmtpConfiguration("smtp.example.com\npassword=wrong", "587", "user@example.com"),
            "smtpServer must be a single line",
        ),
        (
            SmtpConfiguration("smtp.example.com", "587\rwrong", "user@example.com"),
            "smtpServerPort must be a single line",
        ),
        (
            SmtpConfiguration("smtp.example.com", "587", "user@example.com\npassword=wrong"),
            "smtpUser must be a single line",
        ),
    ],
)
def test_requires_git_smtp_configuration(
    configuration: SmtpConfiguration,
    message: str,
) -> None:
    status, _, stderr = invoke("password", store=RecordingCredentialStore(configuration))

    assert status == 1
    assert message in stderr


def test_git_store_reads_effective_configuration_and_approves_the_credential() -> None:
    runner = FakeCommandRunner(
        [
            CommandResult(0, "smtp.example.com\n"),
            CommandResult(1),
            CommandResult(0, "user@example.com\n"),
            CommandResult(0),
        ]
    )
    store = GitCredentialStore(runner)

    configuration = store.configuration()
    store.approve(SmtpCredential(configuration.host, configuration.require_user(), "secret"))

    assert configuration == SmtpConfiguration("smtp.example.com", None, "user@example.com")
    approval_arguments, approval_input = runner.calls[-1]
    assert approval_arguments == (
        "git",
        "-c",
        "credential.helper=",
        "-c",
        "credential.helper=osxkeychain",
        "credential",
        "approve",
    )
    assert approval_input == (
        "protocol=smtp\nhost=smtp.example.com\nusername=user@example.com\npassword=secret\n\n"
    )


@pytest.mark.parametrize(
    ("results", "operation"),
    [
        ([CommandResult(2)], "git config"),
        (
            [
                CommandResult(0, "smtp.example.com\n"),
                CommandResult(1),
                CommandResult(0, "user@example.com\n"),
                CommandResult(1),
            ],
            "Git could not store",
        ),
    ],
)
def test_reports_git_failures(results: Sequence[CommandResult], operation: str) -> None:
    runner = FakeCommandRunner(results)
    store = GitCredentialStore(runner)

    if operation == "git config":
        with pytest.raises(StoreError, match=operation):
            store.configuration()
    else:
        configuration = store.configuration()
        with pytest.raises(StoreError, match=operation):
            store.approve(
                SmtpCredential(configuration.host, configuration.require_user(), "secret")
            )
