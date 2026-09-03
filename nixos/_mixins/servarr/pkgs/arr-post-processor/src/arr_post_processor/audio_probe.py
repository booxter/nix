from __future__ import annotations

import os
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from pydantic import BaseModel, Field, ValidationError

from .errors import SourceInvalid


class ProbeStream(BaseModel):
    codec_type: str


class ProbeFormat(BaseModel):
    duration: str


class ProbeResponse(BaseModel):
    streams: list[ProbeStream] = Field(default_factory=list)
    format: ProbeFormat


class AudioVerifier(Protocol):
    def verify(self, path: Path) -> None: ...


class CommandAudioVerifier:
    def __init__(
        self,
        *,
        ffprobe: str | None = None,
        flac: str | None = None,
        timeout_seconds: float = 300,
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    ) -> None:
        self.ffprobe = ffprobe or os.environ["ARR_POST_PROCESSOR_FFPROBE"]
        self.flac = flac or os.environ["ARR_POST_PROCESSOR_FLAC"]
        self.timeout_seconds = timeout_seconds
        self.run = run

    def verify(self, path: Path) -> None:
        if path.suffix.lower() == ".flac":
            result = self.run(
                [self.flac, "--silent", "--test", str(path)],
                check=False,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=self.timeout_seconds,
            )
            if result.returncode != 0:
                raise SourceInvalid(f"FLAC verification failed for {path}: {result.stderr.strip()}")
        result = self.run(
            [
                self.ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration:stream=codec_type",
                "-of",
                "json",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=self.timeout_seconds,
        )
        if result.returncode != 0:
            raise SourceInvalid(
                f"ffprobe failed for repair candidate {path}: {result.stderr.strip()}"
            )
        try:
            payload = ProbeResponse.model_validate_json(result.stdout)
            duration = float(payload.format.duration)
        except (ValidationError, ValueError) as error:
            raise SourceInvalid(f"ffprobe returned invalid metadata for {path}") from error
        if duration <= 0 or not any(stream.codec_type == "audio" for stream in payload.streams):
            raise SourceInvalid(f"repair candidate has no positive-duration audio stream: {path}")
