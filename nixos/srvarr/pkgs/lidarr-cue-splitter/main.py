#!/usr/bin/env python3

import argparse
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Any, Callable


LOG = logging.getLogger("lidarr-cue-splitter")
STAGING_DIR_NAME = "_lidarr-cue-split"
SUPPORTED_PROTOCOLS = {
    "torrent",
    "torrentdownloadprotocol",
    "usenet",
    "usenetdownloadprotocol",
}
TERMINAL_COMMAND_STATES = {"completed", "failed", "aborted", "cancelled", "orphaned"}
ACTIVE_JOB_STATES = {
    "settling",
    "splitting",
    "verifying",
    "matching",
    "importing",
    "awaiting_queue_removal",
}
PROCESSING_JOB_STATES = {"splitting", "verifying", "matching", "importing"}


class CueSplitterError(RuntimeError):
    pass


class NeedsAttention(CueSplitterError):
    pass


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)


def is_within(path: Path, roots: list[Path]) -> bool:
    resolved = path.resolve()
    return any(
        resolved == root.resolve() or resolved.is_relative_to(root.resolve())
        for root in roots
    )


def safe_component(value: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")[:48] or "download"
    digest = hashlib.sha256(value.encode()).hexdigest()[:12]
    return f"{readable}-{digest}"


def read_api_key(config_path: Path) -> str:
    try:
        root = ET.parse(config_path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise CueSplitterError(
            f"cannot read Lidarr config {config_path}: {exc}"
        ) from exc
    api_key = (root.findtext("ApiKey") or "").strip()
    if not api_key:
        raise CueSplitterError(f"Lidarr config {config_path} does not contain ApiKey")
    return api_key


class LidarrClient:
    def __init__(self, base_url: str, api_key: str, timeout_seconds: float = 20.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds

    def request(
        self,
        method: str,
        endpoint: str,
        *,
        query: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
    ) -> Any:
        url = f"{self.base_url}/api/v1/{endpoint.lstrip('/')}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        data = None
        headers = {"Accept": "application/json", "X-Api-Key": self.api_key}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(
                request, timeout=self.timeout_seconds
            ) as response:
                payload = response.read()
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
            raise CueSplitterError(f"Lidarr {method} {endpoint} failed: {exc}") from exc
        if not payload:
            return None
        try:
            return json.loads(payload)
        except json.JSONDecodeError as exc:
            raise CueSplitterError(
                f"Lidarr {method} {endpoint} returned invalid JSON"
            ) from exc

    def queue(self) -> list[dict[str, Any]]:
        payload = self.request(
            "GET",
            "queue",
            query={
                "page": 1,
                "pageSize": 2000,
                "sortKey": "timeleft",
                "includeUnknownArtistItems": "true",
            },
        )
        if not isinstance(payload, dict) or not isinstance(
            payload.get("records"), list
        ):
            raise CueSplitterError("Lidarr queue response has an unexpected shape")
        return payload["records"]

    def manual_import(
        self, folder: Path, record: dict[str, Any]
    ) -> list[dict[str, Any]]:
        payload = self.request(
            "GET",
            "manualimport",
            query={
                "folder": str(folder),
                "downloadId": record.get("downloadId", ""),
                "artistId": int(record.get("artistId") or 0),
                "replaceExistingFiles": "true",
                "filterExistingFiles": "false",
            },
        )
        if not isinstance(payload, list):
            raise CueSplitterError(
                "Lidarr manual-import response has an unexpected shape"
            )
        return payload

    def submit_manual_import(self, files: list[dict[str, Any]]) -> int:
        payload = self.request(
            "POST",
            "command",
            body={
                "name": "ManualImport",
                "files": files,
                "importMode": "auto",
                "replaceExistingFiles": True,
            },
        )
        command_id = payload.get("id") if isinstance(payload, dict) else None
        if not isinstance(command_id, int) or command_id <= 0:
            raise CueSplitterError("Lidarr did not return a manual-import command ID")
        return command_id

    def command(self, command_id: int) -> dict[str, Any]:
        payload = self.request("GET", f"command/{command_id}")
        if not isinstance(payload, dict):
            raise CueSplitterError("Lidarr command response has an unexpected shape")
        return payload


class UnflacRunner:
    def __init__(
        self, run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run
    ):
        self.run = run

    def inspect(self, cue: Path) -> list[dict[str, Any]]:
        result = self.run(
            ["unflac", "-d", "-j", str(cue)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise CueSplitterError(
                f"unflac could not parse {cue}: {result.stderr.strip()}"
            )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise CueSplitterError(
                f"unflac returned invalid inspection JSON for {cue}"
            ) from exc
        if not isinstance(payload, list) or not payload:
            raise CueSplitterError(f"unflac found no input in {cue}")
        return payload

    def split(self, cue: Path, output_dir: Path) -> list[Path]:
        result = self.run(
            ["unflac", "-f", "flac", "-o", str(output_dir), str(cue)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise CueSplitterError(f"unflac failed for {cue}: {result.stderr.strip()}")
        return sorted(
            path.resolve() for path in output_dir.rglob("*.flac") if path.is_file()
        )

    def verify_flac(self, path: Path) -> None:
        result = self.run(
            ["flac", "--silent", "--test", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise CueSplitterError(
                f"FLAC verification failed for {path}: {result.stderr.strip()}"
            )


def inspection_summary(cue: Path, payload: list[dict[str, Any]]) -> dict[str, Any]:
    audio_files: list[Path] = []
    track_count = 0
    has_image = False
    for item in payload:
        for audio in item.get("audio", []):
            path = Path(str(audio.get("path", "")))
            if not path.is_absolute():
                path = cue.parent / path
            tracks = audio.get("tracks", [])
            if not isinstance(tracks, list):
                raise CueSplitterError(
                    f"unflac inspection has invalid tracks for {cue}"
                )
            audio_files.append(path.resolve())
            track_count += len(tracks)
            has_image = has_image or len(tracks) > 1
    if not audio_files or track_count == 0:
        raise CueSplitterError(f"unflac inspection found no audio tracks for {cue}")
    return {
        "cue": cue.resolve(),
        "audio_files": audio_files,
        "track_count": track_count,
        "eligible": has_image,
    }


def source_fingerprint(summaries: list[dict[str, Any]]) -> str:
    entries: list[str] = []
    paths: set[Path] = set()
    for summary in summaries:
        paths.add(summary["cue"])
        paths.update(summary["audio_files"])
    for path in sorted(paths):
        stat = path.stat()
        entries.append(f"{path}\0{stat.st_size}\0{stat.st_mtime_ns}")
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def build_manual_import_files(
    outputs: list[dict[str, Any]],
    generated_files: list[Path],
    record: dict[str, Any],
) -> list[dict[str, Any]]:
    generated = {path.resolve() for path in generated_files}
    selected: dict[Path, dict[str, Any]] = {}
    expected_artist = int(record.get("artistId") or 0)
    expected_album = int(record.get("albumId") or 0)
    for output in outputs:
        path = Path(str(output.get("path", ""))).resolve()
        if path not in generated:
            continue
        rejections = output.get("rejections") or []
        if rejections:
            reasons = "; ".join(
                str(item.get("reason", "rejected")) for item in rejections
            )
            raise NeedsAttention(f"Lidarr rejected {path.name}: {reasons}")
        artist_id = int((output.get("artist") or {}).get("id") or 0)
        album_id = int((output.get("album") or {}).get("id") or 0)
        if expected_artist and artist_id != expected_artist:
            raise NeedsAttention(
                f"Lidarr matched {path.name} to artist {artist_id}, expected {expected_artist}"
            )
        if expected_album and album_id != expected_album:
            raise NeedsAttention(
                f"Lidarr matched {path.name} to album {album_id}, expected {expected_album}"
            )
        track_ids = [
            int(track["id"]) for track in output.get("tracks", []) if track.get("id")
        ]
        if not track_ids:
            raise NeedsAttention(f"Lidarr did not match {path.name} to a track")
        selected[path] = {
            "path": str(path),
            "artistId": artist_id,
            "albumId": album_id,
            "albumReleaseId": int(output.get("albumReleaseId") or 0),
            "trackIds": track_ids,
            "quality": output.get("quality") or {},
            "indexerFlags": 0,
            "downloadId": output.get("downloadId") or record.get("downloadId", ""),
            "disableReleaseSwitching": bool(
                output.get("disableReleaseSwitching", False)
            ),
        }
    missing = generated - selected.keys()
    if missing:
        names = ", ".join(sorted(path.name for path in missing))
        raise NeedsAttention(f"Lidarr did not return every generated track: {names}")
    return [selected[path] for path in sorted(selected)]


class StateStore:
    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, Any] = {
            "jobs": {},
            "totals": {"success": 0, "failed": 0, "ignored": 0, "tracks": 0},
            "last_success": None,
            "last_duration": 0.0,
        }
        self.load()

    def load(self) -> None:
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except (OSError, json.JSONDecodeError) as exc:
            raise CueSplitterError(f"cannot load state {self.path}: {exc}") from exc
        if isinstance(loaded, dict):
            self.data.update(loaded)
            self.data.setdefault("jobs", {})
            self.data.setdefault("totals", {})

    def save(self) -> None:
        atomic_write(self.path, json.dumps(self.data, indent=2, sort_keys=True) + "\n")

    def prune(self, now: float, retention_seconds: float = 7 * 86400) -> None:
        self.data["jobs"] = {
            key: value
            for key, value in self.data["jobs"].items()
            if value.get("status") not in {"complete", "ignored"}
            or now - float(value.get("updated_at", now)) < retention_seconds
        }


def prometheus_metrics(store: StateStore, ok: bool, now: float) -> str:
    states = Counter(
        job.get("status", "unknown") for job in store.data["jobs"].values()
    )
    totals = store.data.get("totals", {})
    lines = [
        "# HELP host_observability_lidarr_cue_splitter_ok Whether the latest service iteration completed successfully.",
        "# TYPE host_observability_lidarr_cue_splitter_ok gauge",
        f"host_observability_lidarr_cue_splitter_ok {1 if ok else 0}",
        "# HELP host_observability_lidarr_cue_splitter_last_run_timestamp_seconds Unix timestamp of the latest iteration.",
        "# TYPE host_observability_lidarr_cue_splitter_last_run_timestamp_seconds gauge",
        f"host_observability_lidarr_cue_splitter_last_run_timestamp_seconds {now}",
        "# HELP host_observability_lidarr_cue_splitter_active Whether a split or import job is active.",
        "# TYPE host_observability_lidarr_cue_splitter_active gauge",
        f"host_observability_lidarr_cue_splitter_active {1 if any(states[state] for state in ACTIVE_JOB_STATES) else 0}",
        "# HELP host_observability_lidarr_cue_splitter_jobs Number of known jobs by state.",
        "# TYPE host_observability_lidarr_cue_splitter_jobs gauge",
    ]
    for state in sorted(
        set(states) | ACTIVE_JOB_STATES | {"failed", "needs_attention"}
    ):
        lines.append(
            f'host_observability_lidarr_cue_splitter_jobs{{state="{state}"}} {states[state]}'
        )
    lines.extend(
        [
            "# HELP host_observability_lidarr_cue_splitter_jobs_total Jobs handled by result.",
            "# TYPE host_observability_lidarr_cue_splitter_jobs_total counter",
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="success"}} {int(totals.get("success", 0))}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="failed"}} {int(totals.get("failed", 0))}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="ignored"}} {int(totals.get("ignored", 0))}',
            "# HELP host_observability_lidarr_cue_splitter_tracks_total Tracks generated by successful jobs.",
            "# TYPE host_observability_lidarr_cue_splitter_tracks_total counter",
            f"host_observability_lidarr_cue_splitter_tracks_total {int(totals.get('tracks', 0))}",
            "# HELP host_observability_lidarr_cue_splitter_last_job_duration_seconds Duration of the latest successful job.",
            "# TYPE host_observability_lidarr_cue_splitter_last_job_duration_seconds gauge",
            f"host_observability_lidarr_cue_splitter_last_job_duration_seconds {float(store.data.get('last_duration', 0.0))}",
        ]
    )
    if store.data.get("last_success") is not None:
        lines.extend(
            [
                "# HELP host_observability_lidarr_cue_splitter_last_success_timestamp_seconds Unix timestamp of the latest successful import.",
                "# TYPE host_observability_lidarr_cue_splitter_last_success_timestamp_seconds gauge",
                f"host_observability_lidarr_cue_splitter_last_success_timestamp_seconds {float(store.data['last_success'])}",
            ]
        )
    return "\n".join(lines) + "\n"


class CueSplitterService:
    def __init__(
        self,
        *,
        client_factory: Callable[[], LidarrClient],
        runner: UnflacRunner,
        store: StateStore,
        allowed_roots: list[Path],
        work_root: Path,
        metrics_file: Path,
        settle_seconds: float,
        command_timeout_seconds: float,
        now: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.client_factory = client_factory
        self.runner = runner
        self.store = store
        self.allowed_roots = [root.resolve() for root in allowed_roots]
        self.work_root = work_root.resolve()
        self.metrics_file = metrics_file
        self.settle_seconds = settle_seconds
        self.command_timeout_seconds = command_timeout_seconds
        self.now = now
        self.sleep = sleep

    @staticmethod
    def completed_record(record: dict[str, Any]) -> bool:
        return (
            str(record.get("status", "")).lower() == "completed"
            and str(record.get("protocol", "")).lower() in SUPPORTED_PROTOCOLS
            and bool(record.get("downloadId"))
            and bool(record.get("outputPath"))
        )

    def discover(self, record: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
        output_path = Path(str(record["outputPath"]))
        if not is_within(output_path, self.allowed_roots):
            raise NeedsAttention(
                f"download path is outside allowed roots: {output_path}"
            )
        if not output_path.is_dir():
            raise CueSplitterError(f"download path does not exist: {output_path}")
        cues = sorted(
            path
            for path in output_path.rglob("*")
            if path.is_file()
            and path.suffix.lower() == ".cue"
            and STAGING_DIR_NAME not in path.parts
        )
        summaries = []
        for cue in cues:
            summary = inspection_summary(cue, self.runner.inspect(cue))
            if not is_within(summary["cue"], self.allowed_roots) or any(
                not is_within(path, self.allowed_roots)
                for path in summary["audio_files"]
            ):
                raise NeedsAttention(
                    f"CUE references audio outside allowed roots: {cue}"
                )
            if summary["eligible"]:
                summaries.append(summary)
        return summaries, source_fingerprint(summaries) if summaries else ""

    def process(
        self, client: LidarrClient, record: dict[str, Any], job: dict[str, Any]
    ) -> None:
        started = self.now()
        summaries, fingerprint = self.discover(record)
        if fingerprint != job["fingerprint"]:
            job.update(
                status="settling",
                fingerprint=fingerprint,
                discovered_at=started,
                updated_at=started,
            )
            return
        component = safe_component(str(record["downloadId"]))
        partial_root = self.work_root / f"{component}.partial"
        output_path = Path(str(record["outputPath"])).resolve()
        ready_root = output_path / STAGING_DIR_NAME / component
        if partial_root.exists():
            shutil.rmtree(partial_root)
        if ready_root.exists():
            shutil.rmtree(ready_root)
        partial_root.mkdir(parents=True)
        generated: list[Path] = []
        expected_tracks = 0
        try:
            job.update(status="splitting", updated_at=self.now())
            self.store.save()
            for index, summary in enumerate(summaries, start=1):
                cue_output = (
                    partial_root
                    / f"disc-{index:02d}-{safe_component(summary['cue'].stem)}"
                )
                cue_output.mkdir(parents=True)
                generated.extend(self.runner.split(summary["cue"], cue_output))
                expected_tracks += int(summary["track_count"])
            if len(generated) != expected_tracks:
                raise CueSplitterError(
                    f"unflac generated {len(generated)} tracks; expected {expected_tracks}"
                )
            job.update(status="verifying", updated_at=self.now())
            self.store.save()
            for path in generated:
                self.runner.verify_flac(path)
            ready_root.parent.mkdir(parents=True, exist_ok=True)
            os.replace(partial_root, ready_root)
            generated = sorted(path.resolve() for path in ready_root.rglob("*.flac"))
            job.update(
                status="matching",
                ready_root=str(ready_root),
                tracks=len(generated),
                updated_at=self.now(),
            )
            self.store.save()
            outputs = client.manual_import(ready_root, record)
            import_files = build_manual_import_files(outputs, generated, record)
            job.update(status="importing", updated_at=self.now())
            self.store.save()
            command_id = client.submit_manual_import(import_files)
            job["command_id"] = command_id
            deadline = time.monotonic() + self.command_timeout_seconds
            while time.monotonic() < deadline:
                command = client.command(command_id)
                status = str(command.get("status", "")).lower()
                if status in TERMINAL_COMMAND_STATES:
                    if status != "completed":
                        raise NeedsAttention(
                            f"Lidarr manual-import command {command_id} ended as {status}: {command.get('message', '')}"
                        )
                    break
                self.sleep(2.0)
            else:
                raise NeedsAttention(
                    f"Lidarr manual-import command {command_id} timed out"
                )
            job.update(status="awaiting_queue_removal", updated_at=self.now())
            self.store.save()
        except Exception:
            if partial_root.exists():
                shutil.rmtree(partial_root)
            raise

    def complete_job(
        self, job: dict[str, Any], ready_root: Path, started: float
    ) -> None:
        if STAGING_DIR_NAME not in ready_root.parts or not is_within(
            ready_root, self.allowed_roots
        ):
            raise NeedsAttention(f"refusing to clean unsafe staging path: {ready_root}")
        if ready_root.exists():
            shutil.rmtree(ready_root)
        parent = ready_root.parent
        if parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
        finished = self.now()
        job.update(status="complete", updated_at=finished, error="")
        totals = self.store.data["totals"]
        totals["success"] = int(totals.get("success", 0)) + 1
        totals["tracks"] = int(totals.get("tracks", 0)) + int(job.get("tracks", 0))
        self.store.data["last_success"] = finished
        self.store.data["last_duration"] = max(0.0, finished - started)
        LOG.info(
            "completed cue split/import: download_id=%s tracks=%s",
            job["download_id"],
            job.get("tracks", 0),
        )

    def iteration(self) -> None:
        now = self.now()
        client = self.client_factory()
        records = client.queue()
        completed = {
            str(record["downloadId"]): record
            for record in records
            if self.completed_record(record)
        }
        jobs = self.store.data["jobs"]

        for job in jobs.values():
            if job.get("status") in PROCESSING_JOB_STATES:
                job.update(
                    status="failed",
                    error="service restarted while the job was processing; the job will be retried",
                    updated_at=now,
                    attempts=int(job.get("attempts", 0)) + 1,
                )

        for job in jobs.values():
            if (
                job.get("status") == "awaiting_queue_removal"
                and job.get("download_id") not in completed
            ):
                self.complete_job(
                    job, Path(job["ready_root"]), float(job.get("started_at", now))
                )
            elif (
                job.get("status") == "awaiting_queue_removal"
                and now - float(job.get("updated_at", now))
                > self.command_timeout_seconds
            ):
                job.update(
                    status="needs_attention",
                    error="Lidarr manual import completed but the download remained in the activity queue",
                    updated_at=now,
                )
                self.store.data["totals"]["failed"] = (
                    int(self.store.data["totals"].get("failed", 0)) + 1
                )

        if not any(job.get("status") in PROCESSING_JOB_STATES for job in jobs.values()):
            for download_id, record in completed.items():
                existing = jobs.get(download_id)
                if existing and existing.get("status") in {
                    "complete",
                    "awaiting_queue_removal",
                }:
                    continue
                try:
                    summaries, fingerprint = self.discover(record)
                    if not summaries:
                        if not existing or existing.get("status") != "ignored":
                            job = jobs.setdefault(
                                download_id, {"download_id": download_id}
                            )
                            job.update(
                                status="ignored",
                                updated_at=now,
                                fingerprint="",
                                error="",
                            )
                            self.store.data["totals"]["ignored"] = (
                                int(self.store.data["totals"].get("ignored", 0)) + 1
                            )
                        continue
                    if not existing or existing.get("fingerprint") != fingerprint:
                        jobs[download_id] = {
                            "download_id": download_id,
                            "title": record.get("title", ""),
                            "status": "settling",
                            "fingerprint": fingerprint,
                            "discovered_at": now,
                            "updated_at": now,
                            "attempts": 0,
                        }
                        LOG.info(
                            "discovered CUE image: download_id=%s title=%s",
                            download_id,
                            record.get("title", ""),
                        )
                        break
                    if existing.get("status") == "needs_attention":
                        continue
                    if existing.get("status") == "failed":
                        if int(existing.get("attempts", 0)) >= 3:
                            existing.update(status="needs_attention", updated_at=now)
                            continue
                        if now - float(existing.get("updated_at", now)) < 300:
                            continue
                    if (
                        now - float(existing.get("discovered_at", now))
                        < self.settle_seconds
                    ):
                        continue
                    existing["started_at"] = now
                    self.process(client, record, existing)
                except NeedsAttention as exc:
                    job = jobs.setdefault(download_id, {"download_id": download_id})
                    job.update(status="needs_attention", error=str(exc), updated_at=now)
                    self.store.data["totals"]["failed"] = (
                        int(self.store.data["totals"].get("failed", 0)) + 1
                    )
                    LOG.error(
                        "cue job needs attention: download_id=%s error=%s",
                        download_id,
                        exc,
                    )
                except Exception as exc:
                    job = jobs.setdefault(download_id, {"download_id": download_id})
                    job.update(
                        status="failed",
                        error=str(exc),
                        updated_at=now,
                        attempts=int(job.get("attempts", 0)) + 1,
                    )
                    self.store.data["totals"]["failed"] = (
                        int(self.store.data["totals"].get("failed", 0)) + 1
                    )
                    LOG.exception("cue job failed: download_id=%s", download_id)
                break
        self.store.prune(now)
        self.store.save()

    def write_metrics(self, ok: bool) -> None:
        atomic_write(self.metrics_file, prometheus_metrics(self.store, ok, self.now()))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split completed Lidarr CUE images and import the generated tracks."
    )
    parser.add_argument("--lidarr-url", default="http://127.0.0.1:8686")
    parser.add_argument("--lidarr-config", required=True)
    parser.add_argument("--allowed-root", action="append", required=True)
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--interval-seconds", type=float, default=30.0)
    parser.add_argument("--settle-seconds", type=float, default=30.0)
    parser.add_argument("--request-timeout-seconds", type=float, default=20.0)
    parser.add_argument("--command-timeout-seconds", type=float, default=900.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument(
        "--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"]
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    store = StateStore(Path(args.state_file))

    def client_factory() -> LidarrClient:
        return LidarrClient(
            args.lidarr_url,
            read_api_key(Path(args.lidarr_config)),
            args.request_timeout_seconds,
        )

    service = CueSplitterService(
        client_factory=client_factory,
        runner=UnflacRunner(),
        store=store,
        allowed_roots=[Path(root) for root in args.allowed_root],
        work_root=Path(args.work_root),
        metrics_file=Path(args.metrics_file),
        settle_seconds=args.settle_seconds,
        command_timeout_seconds=args.command_timeout_seconds,
    )
    while True:
        started = time.monotonic()
        ok = True
        try:
            service.iteration()
        except Exception:
            ok = False
            LOG.exception("service iteration failed")
        service.write_metrics(ok)
        if args.once:
            return 0 if ok else 1
        time.sleep(max(0.0, args.interval_seconds - (time.monotonic() - started)))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(0)
