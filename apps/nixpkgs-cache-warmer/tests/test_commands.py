import io
import sys

from nixpkgs_cache_warmer.commands import SubprocessCommandRunner


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
