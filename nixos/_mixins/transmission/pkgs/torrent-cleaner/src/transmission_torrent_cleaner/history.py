"""Bounded upload observations, stored locally rather than in monitoring metrics."""

import os
import tempfile
from itertools import pairwise
from pathlib import Path
from typing import Protocol

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

HOUR_SECONDS = 3600


class HistoryError(ValueError):
    pass


class Sample(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    timestamp: float = Field(allow_inf_nan=False)
    uploaded_bytes: int = Field(ge=0)


class TorrentHistory(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    completed_at: int
    samples: list[Sample]
    last_observation: Sample

    @model_validator(mode="after")
    def validate_observations(self) -> "TorrentHistory":
        if not self.samples:
            raise ValueError("history must contain a sample")
        observations = [*self.samples, self.last_observation]
        for previous, current in pairwise(observations):
            if (
                current.timestamp < previous.timestamp
                or current.uploaded_bytes < previous.uploaded_bytes
            ):
                raise ValueError("history observations must be monotonic")
        return self


class UploadHistory(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    torrents: dict[str, TorrentHistory] = Field(default_factory=dict)


class HistoryStore(Protocol):
    def load(self) -> UploadHistory: ...

    def save(self, history: UploadHistory) -> None: ...


class FileHistoryStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> UploadHistory:
        try:
            return UploadHistory.model_validate_json(self.path.read_bytes())
        except FileNotFoundError:
            return UploadHistory()
        except ValidationError as exc:
            raise HistoryError("invalid upload history; cleanup skipped") from exc

    def save(self, history: UploadHistory) -> None:
        # Atomic replacement prevents a crash from leaving partial history behind.
        descriptor, name = tempfile.mkstemp(dir=self.path.parent, prefix=".upload-history-")
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w") as stream:
                stream.write(history.model_dump_json())
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(self.path)
        finally:
            temporary.unlink(missing_ok=True)


def observe_upload(
    previous: TorrentHistory | None,
    *,
    completed_at: int,
    uploaded_bytes: int,
    now: float,
    window_seconds: float,
) -> tuple[TorrentHistory, float | None]:
    sample = Sample(timestamp=now, uploaded_bytes=uploaded_bytes)
    samples = [] if previous is None else previous.samples
    if previous is not None:
        latest = previous.last_observation
        # A new completion, counter reset, clock reversal, or observation outage
        # starts a fresh window. Missing observations must not look like inactivity.
        if (
            previous.completed_at != completed_at
            or uploaded_bytes < latest.uploaded_bytes
            or not 0 <= now - latest.timestamp <= 2 * HOUR_SECONDS
        ):
            samples = []

    cutoff = now - window_seconds
    older = [entry for entry in samples if entry.timestamp <= cutoff]
    baseline = older[-1] if older else None
    rate = None
    if baseline is not None:
        # Include the boundary hour's bytes but not its extra time. This upper
        # estimate protects uploaders at the threshold between hourly samples.
        rate = (uploaded_bytes - baseline.uploaded_bytes) / window_seconds

    # Keep hourly samples and the one immediately before the rolling window.
    # Always compare against the current counter, even between stored samples.
    retained = [entry for entry in samples if entry.timestamp > cutoff]
    if baseline is not None:
        retained.insert(0, baseline)
    if not retained or now - retained[-1].timestamp >= HOUR_SECONDS:
        retained.append(sample)
    return TorrentHistory(
        completed_at=completed_at, samples=retained, last_observation=sample
    ), rate
