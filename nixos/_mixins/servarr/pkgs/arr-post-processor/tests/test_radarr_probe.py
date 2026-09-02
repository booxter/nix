from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from arr_post_processor.errors import SourceInvalid
from arr_post_processor.radarr_probe import CommandVideoVerifier


def completed(stdout: str, *, returncode: int = 0) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], returncode, stdout, "probe error")


def test_verifier_accepts_positive_duration_video(tmp_path: Path) -> None:
    candidate = tmp_path / "movie.mkv"
    candidate.write_bytes(b"media")
    verifier = CommandVideoVerifier(
        ffprobe="ffprobe",
        run=lambda *args, **kwargs: completed(
            '{"streams":[{"codec_type":"video"}],"format":{"duration":"7200.5"}}'
        ),
    )

    verifier.verify(candidate)


@pytest.mark.parametrize(
    ("result", "message"),
    [
        (completed("", returncode=1), "ffprobe failed"),
        (completed("not json"), "invalid metadata"),
        (completed('{"streams":[],"format":{"duration":"0"}}'), "positive duration"),
        (completed('{"streams":[],"format":{"duration":"10"}}'), "video stream"),
    ],
)
def test_verifier_rejects_invalid_media(
    tmp_path: Path, result: subprocess.CompletedProcess[str], message: str
) -> None:
    verifier = CommandVideoVerifier(ffprobe="ffprobe", run=lambda *args, **kwargs: result)

    with pytest.raises(SourceInvalid, match=message):
        verifier.verify(tmp_path / "movie.mkv")
