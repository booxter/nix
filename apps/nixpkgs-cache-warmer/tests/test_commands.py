import io
import sys

from nixpkgs_cache_warmer.commands import SubprocessCommandRunner


def test_replaces_invalid_utf8_in_captured_output() -> None:
    result = SubprocessCommandRunner().run(
        (
            sys.executable,
            "-c",
            "import sys; sys.stdout.buffer.write(b'output \\x8b\\n')",
        )
    )

    assert result.returncode == 0
    assert result.stdout == "output \ufffd\n"
    assert result.stderr == ""


def test_streams_standard_error_while_retaining_standard_output() -> None:
    stderr = io.StringIO()

    result = SubprocessCommandRunner().run_streaming(
        (
            sys.executable,
            "-c",
            "import sys; print('output'); print('progress', file=sys.stderr)",
        ),
        stderr,
    )

    assert result.returncode == 0
    assert result.stdout == "output\n"
    assert result.stderr == ""
    assert stderr.getvalue() == "progress\n"


def test_replaces_invalid_utf8_in_streamed_standard_error() -> None:
    stderr = io.StringIO()

    result = SubprocessCommandRunner().run_streaming(
        (
            sys.executable,
            "-c",
            "import sys; sys.stderr.buffer.write(b'progress \\x8b\\n')",
        ),
        stderr,
    )

    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""
    assert stderr.getvalue() == "progress \ufffd\n"
