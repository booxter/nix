from __future__ import annotations

import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .errors import NeedsAttention, PostProcessorError, SourceInvalid
from .media import (
    AUDIO_FILE_SUFFIXES,
    LEGACY_STAGING_DIR_NAME,
    STAGING_DIR_NAME,
    MediaRunner,
    cue_already_split_audio_files,
    inspection_summary,
    is_staging_path,
    is_within,
    output_fingerprint,
    safe_component,
)
from .models import CueSummary

LOG = logging.getLogger("arr-post-processor.lidarr.pipeline")


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
            path
            for path in source.rglob("*")
            if path.is_file()
            and not is_staging_path(path.relative_to(source))
            and path.suffix.lower() == ".cue"
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
            LOG.info(
                "splitting CUE: cue=%s tracks=%s destination=%s",
                summary.cue,
                summary.track_count,
                cue_output,
            )
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

    def job_root(self, source: Path, download_id: str) -> Path:
        resolved = self.validate_source(source)
        return resolved / STAGING_DIR_NAME / safe_component(download_id)

    def execute(self, source: Path, download_id: str) -> PipelineResult:
        source_root = self.validate_source(source)
        current = source_root
        ready_root = self.job_root(source_root, download_id)
        partial_root = ready_root.with_name(f"{ready_root.name}.partial")
        self.cleanup_source_path(partial_root, source_root)
        self.cleanup_source_path(ready_root, source_root)
        partial_root.mkdir(parents=True)
        applied: list[str] = []
        LOG.info(
            "starting transformation pipeline: download_id=%s source=%s staging=%s",
            download_id,
            source_root,
            partial_root,
        )
        try:
            for index, transform in enumerate(self.transforms, start=1):
                if not transform.applies(current):
                    LOG.info(
                        "skipping transformation: download_id=%s transform=%s "
                        "reason=not_applicable",
                        download_id,
                        transform.name,
                    )
                    continue
                destination = partial_root / f"{index:02d}-{transform.name}"
                LOG.info(
                    "applying transformation: download_id=%s transform=%s input=%s output=%s",
                    download_id,
                    transform.name,
                    current,
                    destination,
                )
                result = transform.apply(current, destination)
                current = result.root.resolve()
                applied.append(transform.name)
                LOG.info(
                    "completed transformation: download_id=%s transform=%s artifacts=%s",
                    download_id,
                    transform.name,
                    result.artifacts,
                )
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
            LOG.info(
                "transformation pipeline ready for import: download_id=%s transforms=%s "
                "tracks=%s path=%s",
                download_id,
                "+".join(applied),
                len(audio_files),
                final_root,
            )
            return PipelineResult(
                ready_root=final_root,
                audio_files=audio_files,
                transforms=tuple(applied),
            )
        except Exception:
            LOG.info(
                "cleaning incomplete transformation staging: download_id=%s staging=%s",
                download_id,
                partial_root,
            )
            self.cleanup_source_path(partial_root, source_root)
            self.cleanup_source_path(ready_root, source_root)
            raise

    def cleanup(self, download_id: str, ready_root: Path | None) -> None:
        component = safe_component(download_id)
        self.cleanup_global_path(self.work_root / component)
        self.cleanup_global_path(self.work_root / f"{component}.partial")
        if ready_root is None:
            return
        resolved = ready_root.resolve()
        if is_within(resolved, [self.work_root]):
            return
        try:
            staging_index = resolved.parts.index(STAGING_DIR_NAME)
        except ValueError:
            return
        if staging_index + 1 >= len(resolved.parts):
            raise NeedsAttention(f"refusing to clean malformed staging path: {ready_root}")
        job_root = Path(*resolved.parts[: staging_index + 2])
        if job_root.name != component or not is_within(job_root, self.allowed_roots):
            raise NeedsAttention(f"refusing to clean unsafe staging path: {ready_root}")
        if job_root.exists():
            LOG.info("cleaning job staging: download_id=%s path=%s", download_id, job_root)
            shutil.rmtree(job_root)
        staging_root = job_root.parent
        if staging_root.exists() and not any(staging_root.iterdir()):
            staging_root.rmdir()

    def cleanup_legacy_cue_staging(self, ready_root: Path) -> None:
        resolved = ready_root.resolve()
        if LEGACY_STAGING_DIR_NAME not in resolved.parts or not is_within(
            resolved, self.allowed_roots
        ):
            raise NeedsAttention(f"refusing to clean unsafe legacy staging path: {ready_root}")
        if resolved.exists():
            shutil.rmtree(resolved)
        parent = resolved.parent
        if parent.name == LEGACY_STAGING_DIR_NAME and parent.exists() and not any(parent.iterdir()):
            parent.rmdir()

    def prune_stale(self, now: float, retention_seconds: float) -> None:
        if not self.work_root.exists():
            return
        for path in self.work_root.iterdir():
            try:
                stale = now - path.stat().st_mtime >= retention_seconds
            except OSError:
                continue
            if path.is_dir() and stale:
                self.cleanup_global_path(path)

    def cleanup_global_path(self, path: Path) -> None:
        resolved = path.resolve()
        if resolved.parent != self.work_root:
            raise NeedsAttention(f"refusing to clean unsafe staging path: {path}")
        if resolved.exists():
            shutil.rmtree(resolved)

    @staticmethod
    def cleanup_source_path(path: Path, source: Path) -> None:
        resolved = path.resolve()
        staging_root = source.resolve() / STAGING_DIR_NAME
        if resolved.parent != staging_root:
            raise NeedsAttention(f"refusing to clean unsafe source staging path: {path}")
        if resolved.exists():
            shutil.rmtree(resolved)
        if staging_root.exists() and not any(staging_root.iterdir()):
            staging_root.rmdir()
