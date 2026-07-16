import importlib.util
import subprocess
import sys
from pathlib import Path


CHECKER_PATH = Path(__file__).with_name("check_commit_message.py")


def load_checker_module():
    spec = importlib.util.spec_from_file_location("check_commit_message", CHECKER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run_checker(tmp_path: Path, message: str) -> subprocess.CompletedProcess[str]:
    message_path = tmp_path / "COMMIT_EDITMSG"
    message_path.write_text(message, encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(CHECKER_PATH), str(message_path)],
        text=True,
        capture_output=True,
        check=False,
    )


def test_accepts_subject_only_at_limit(tmp_path):
    result = run_checker(tmp_path, "S" * 72 + "\n")
    assert result.returncode == 0


def test_rejects_subject_over_limit(tmp_path):
    result = run_checker(tmp_path, "S" * 73 + "\n")
    assert result.returncode == 1
    assert "line 1: subject exceeds 72 characters (73 characters)" in result.stderr


def test_counts_unicode_characters_instead_of_bytes(tmp_path):
    result = run_checker(tmp_path, "é" * 72 + "\n")
    assert result.returncode == 0


def test_accepts_wrapped_body(tmp_path):
    result = run_checker(
        tmp_path,
        "Keep commits readable\n\n"
        "This body is split into physical lines that fit within the configured\n"
        "limit instead of relying on an editor to display soft wrapping.\n",
    )
    assert result.returncode == 0


def test_rejects_long_body_prose(tmp_path):
    result = run_checker(
        tmp_path,
        "Reject long prose\n\n" + "word " * 15 + "\n",
    )
    assert result.returncode == 1
    assert "line 3: body prose exceeds 72 characters (75 characters)" in result.stderr
    assert "run `git hook run commit-msg" in result.stderr


def test_requires_blank_line_before_body(tmp_path):
    result = run_checker(tmp_path, "Subject\nBody starts too early\n")
    assert result.returncode == 1
    assert "line 2: subject and body must be separated by a blank line" in result.stderr


def test_accepts_long_single_token(tmp_path):
    result = run_checker(
        tmp_path,
        "Keep tokens intact\n\nhttps://example.com/" + "long-path-segment/" * 6 + "\n",
    )
    assert result.returncode == 0


def test_accepts_long_terminal_trailer(tmp_path):
    result = run_checker(
        tmp_path,
        "Preserve trailers\n\nExplain the change briefly.\n\n"
        'Fixes: 1234567890ab ("' + "long previous subject " * 4 + '")\n',
    )
    assert result.returncode == 0


def test_accepts_long_terminal_trailer_continuation(tmp_path):
    result = run_checker(
        tmp_path,
        "Preserve trailer continuations\n\nExplain the change briefly.\n\n"
        "Release-note: This starts a multiline trailer value.\n "
        + "continued trailer value " * 5
        + "\n",
    )
    assert result.returncode == 0


def test_does_not_treat_mid_body_colon_line_as_trailer(tmp_path):
    result = run_checker(
        tmp_path,
        "Check prose\n\nNote: " + "long prose " * 8 + "\n\nFinal paragraph.\n",
    )
    assert result.returncode == 1
    assert "line 3: body prose exceeds 72 characters" in result.stderr


def test_accepts_long_fenced_and_indented_literal_lines(tmp_path):
    result = run_checker(
        tmp_path,
        "Preserve literal content\n\n"
        "```text\n" + "literal " * 20 + "\n```\n\n    " + "indented " * 20 + "\n",
    )
    assert result.returncode == 0


def test_validate_message_rejects_empty_subject():
    checker = load_checker_module()
    assert checker.validate_message("\n") == [
        checker.Violation(1, 0, "subject must not be empty", "")
    ]
