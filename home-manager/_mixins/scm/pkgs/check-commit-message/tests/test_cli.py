from __future__ import annotations

import io
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from check_commit_message.cli import Violation, main, validate_message


@dataclass(frozen=True)
class FixedCommentPrefix:
    value: str

    def comment_prefix(self) -> str:
        return self.value


def reasons(message: str, comment_prefix: str = "#") -> list[str]:
    return [violation.reason for violation in validate_message(message, comment_prefix)]


def test_subject_and_body_limits_count_characters() -> None:
    assert reasons("é" * 72 + "\n") == []
    assert reasons("S" * 73 + "\n") == ["subject exceeds 72 characters"]
    assert reasons("Subject\n\n" + "word " * 15 + "\n") == ["body prose exceeds 72 characters"]


def test_requires_a_subject_and_blank_separator() -> None:
    assert validate_message("\n") == [Violation(1, 0, "subject must not be empty", "")]
    assert reasons("Subject\nBody starts too early\n") == [
        "subject and body must be separated by a blank line"
    ]


def test_ignores_git_comments_only_at_the_configured_prefix() -> None:
    long_comment = "generated comment prose " * 5
    assert reasons(f"Subject\n\n// {long_comment}\n", "//") == []
    assert reasons(f"Subject\n\n // {long_comment}\n", "//") == ["body prose exceeds 72 characters"]


def test_allows_literal_content_indivisible_tokens_and_terminal_trailers() -> None:
    assert (
        reasons(
            "Preserve literals\n\n"
            "https://example.com/" + "long-path-segment/" * 6 + "\n\n"
            "```text\n" + "literal " * 20 + "\n```\n\n"
            "    " + "indented " * 20 + "\n\n"
            'Fixes: 1234567890ab ("' + "long previous subject " * 4 + '")\n'
        )
        == []
    )


def test_terminal_trailer_continuation_is_exempt() -> None:
    assert (
        reasons(
            "Preserve trailer continuations\n\nExplain the change briefly.\n\n"
            "Release-note: This starts a multiline trailer value.\n "
            + "continued trailer value " * 5
            + "\n"
        )
        == []
    )
    assert reasons("Check prose\n\nNote: " + "long prose " * 8 + "\n\nFinal.\n") == [
        "body prose exceeds 72 characters"
    ]


def test_cli_reports_file_and_format_errors(tmp_path: Path) -> None:
    stderr = io.StringIO()
    missing = tmp_path / "missing"
    assert main([str(missing)], prefix_source=FixedCommentPrefix("#"), stderr=stderr) == 2
    assert "cannot read commit message" in stderr.getvalue()

    message = tmp_path / "COMMIT_EDITMSG"
    message.write_text("Subject\n\n" + "word " * 15 + "\n")
    stderr = io.StringIO()
    assert main([str(message)], prefix_source=FixedCommentPrefix("#"), stderr=stderr) == 1
    assert "line 3: body prose exceeds 72 characters" in stderr.getvalue()
    assert "git hook run commit-msg" in stderr.getvalue()


def git(repo: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    environment = {
        **os.environ,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
    }
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )


def test_real_git_hook_rejects_bad_message_and_preserves_existing_hook(tmp_path: Path) -> None:
    program = Path(os.environ["CHECK_COMMIT_MESSAGE_PROGRAM"])
    repo = tmp_path / "repo"
    repo.mkdir()
    assert git(repo, "init", "--quiet").returncode == 0
    for key, value in (
        ("user.name", "Test"),
        ("user.email", "test@example.com"),
        ("commit.gpgSign", "false"),
        ("core.hooksPath", "custom-hooks"),
        ("hook.commit-message-test.event", "commit-msg"),
        ("hook.commit-message-test.command", str(program)),
    ):
        assert git(repo, "config", key, value).returncode == 0

    hooks = repo / "custom-hooks"
    hooks.mkdir()
    marker = repo / "legacy-hook-ran"
    legacy_hook = hooks / "commit-msg"
    legacy_hook.write_text(
        f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(marker)!r}).touch()\n"
    )
    legacy_hook.chmod(0o755)

    accepted = git(
        repo,
        "commit",
        "--quiet",
        "--allow-empty",
        "-m",
        "Accept a formatted message",
        "-m",
        "This body fits within the configured physical line limit.",
    )
    assert accepted.returncode == 0, accepted.stderr
    assert marker.exists()

    rejected = git(
        repo,
        "commit",
        "--quiet",
        "--allow-empty",
        "-m",
        "Reject an unformatted message",
        "-m",
        "This deliberately long body line must be rejected before Git creates another commit.",
    )
    assert rejected.returncode != 0
    assert "body prose exceeds 72 characters" in rejected.stderr
    assert git(repo, "rev-list", "--count", "HEAD").stdout.strip() == "1"
