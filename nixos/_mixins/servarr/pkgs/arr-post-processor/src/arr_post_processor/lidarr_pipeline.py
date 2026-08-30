from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .errors import NeedsAttention, PostProcessorError, SourceInvalid
from .media import (
    AUDIO_FILE_SUFFIXES,
    MediaRunner,
    cue_already_split_audio_files,
    inspection_summary,
    is_within,
    output_fingerprint,
    safe_component,
)
from .models import CueSummary


@dataclass(frozen=True)
class TransformResult:
    root: Path
    artifacts: int


@dataclass(frozen=True)
class PipelineInspection:
    applicable: bool
    fingerprint: str


@dataclass(frozen=True)
class PipelineResult:
    ready_root: Path
    audio_files: tuple[Path, ...]
    transforms: tuple[str, ...]


class LidarrTransform(Protocol):
    name: str
    input_suffixes: frozenset[str]

    def applies(self, source: Path) -> bool: ...

    def apply(self, source: Path, destination: Path) -> TransformResult: ...


class CueTransform:
    name = "cue_split"
    input_suffixes = frozenset({".cue"}) | AUDIO_FILE_SUFFIXES

    def __init__(self, runner: MediaRunner, allowed_roots: list[Path]):
        self.runner = runner
        self.allowed_roots = [root.resolve() for root in allowed_roots]

    @staticmethod
    def cue_files(source: Path) -> list[Path]:
        return sorted(
            path for path in source.rglob("*") if path.is_file() and path.suffix.lower() == ".cue"
        )

    def already_split(self, source: Path) -> bool:
        cues = self.cue_files(source)
        if not cues:
            return False
        for cue in cues:
            audio_files = cue_already_split_audio_files(cue)
            if audio_files is None:
                return False
            if not is_within(cue, self.allowed_roots) or any(
                not is_within(path, self.allowed_roots) for path in audio_files
            ):
                return False
        return True

    def summaries(self, source: Path) -> list[CueSummary]:
        summaries: list[CueSummary] = []
        for cue in self.cue_files(source):
            already_split_audio_files = cue_already_split_audio_files(cue)
            if already_split_audio_files is not None:
                if not is_within(cue, self.allowed_roots) or any(
                    not is_within(path, self.allowed_roots) for path in already_split_audio_files
                ):
                    raise NeedsAttention(f"CUE references audio outside allowed roots: {cue}")
                continue
            summary = inspection_summary(cue, self.runner.inspect(cue))
            if not is_within(summary.cue, self.allowed_roots) or any(
                not is_within(path, self.allowed_roots) for path in summary.audio_files
            ):
                raise NeedsAttention(f"CUE references audio outside allowed roots: {cue}")
            if summary.eligible:
                summaries.append(summary)
        return summaries

    def applies(self, source: Path) -> bool:
        return bool(self.summaries(source))

    def apply(self, source: Path, destination: Path) -> TransformResult:
        summaries = self.summaries(source)
        if not summaries:
            raise PostProcessorError("CUE transformation is no longer applicable")
        destination.mkdir(parents=True)
        generated: list[Path] = []
        expected_tracks = 0
        for index, summary in enumerate(summaries, start=1):
            cue_output = destination / f"disc-{index:02d}-{safe_component(summary.cue.stem)}"
            cue_output.mkdir(parents=True)
            generated.extend(self.runner.split(summary.cue, cue_output))
            expected_tracks += summary.track_count
        if len(generated) != expected_tracks:
            raise SourceInvalid(
                f"unflac generated {len(generated)} tracks; expected {expected_tracks}"
            )
        for path in generated:
            self.runner.verify_flac(path)
        return TransformResult(root=destination, artifacts=len(generated))


class LidarrPipeline:
    def __init__(
        self,
        *,
        transforms: list[LidarrTransform],
        allowed_roots: list[Path],
        work_root: Path,
    ):
        self.transforms = transforms
        self.allowed_roots = [root.resolve() for root in allowed_roots]
        self.work_root = work_root.resolve()
        self.input_suffixes = frozenset(
            suffix for transform in transforms for suffix in transform.input_suffixes
        )

    def validate_source(self, source: Path) -> Path:
        if not is_within(source, self.allowed_roots):
            raise NeedsAttention(f"download path is outside allowed roots: {source}")
        if not source.is_dir():
            raise PostProcessorError(f"download path does not exist: {source}")
        return source.resolve()

    def inspect(self, source: Path) -> PipelineInspection:
        resolved = self.validate_source(source)
        return PipelineInspection(
            applicable=any(transform.applies(resolved) for transform in self.transforms),
            fingerprint=output_fingerprint(resolved, suffixes=self.input_suffixes),
        )

    def source_is_already_resolved(self, source: Path) -> bool:
        if not source.is_dir() or not is_within(source, self.allowed_roots):
            return False
        resolved = source.resolve()
        return any(
            isinstance(transform, CueTransform) and transform.already_split(resolved)
            for transform in self.transforms
        )

    def job_root(self, download_id: str) -> Path:
        return self.work_root / safe_component(download_id)

    def execute(self, source: Path, download_id: str) -> PipelineResult:
        current = self.validate_source(source)
        ready_root = self.job_root(download_id)
        partial_root = self.work_root / f"{safe_component(download_id)}.partial"
        self.cleanup_path(partial_root)
        self.cleanup_path(ready_root)
        partial_root.mkdir(parents=True)
        applied: list[str] = []
        try:
            for index, transform in enumerate(self.transforms, start=1):
                if not transform.applies(current):
                    continue
                destination = partial_root / f"{index:02d}-{transform.name}"
                result = transform.apply(current, destination)
                current = result.root.resolve()
                applied.append(transform.name)
            if not applied:
                raise PostProcessorError("no Lidarr transformation is applicable")
            relative_result = current.relative_to(partial_root.resolve())
            os.replace(partial_root, ready_root)
            final_root = (ready_root / relative_result).resolve()
            audio_files = tuple(
                sorted(
                    path.resolve()
                    for path in final_root.rglob("*")
                    if path.is_file() and path.suffix.lower() in AUDIO_FILE_SUFFIXES
                )
            )
            if not audio_files:
                raise SourceInvalid("post-processing produced no recognized audio files")
            return PipelineResult(
                ready_root=final_root,
                audio_files=audio_files,
                transforms=tuple(applied),
            )
        except Exception:
            self.cleanup_path(partial_root)
            raise

    def cleanup(self, download_id: str) -> None:
        self.cleanup_path(self.job_root(download_id))

    def cleanup_path(self, path: Path) -> None:
        resolved = path.resolve()
        if resolved.parent != self.work_root:
            raise NeedsAttention(f"refusing to clean unsafe staging path: {path}")
        if resolved.exists():
            shutil.rmtree(resolved)
