#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export B2 bucket and restic cloud repository usage metrics."
    )
    parser.add_argument("--config", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--b2-cli", required=True)
    parser.add_argument("--restic", required=True)
    parser.add_argument("--b2-account-info-file", required=True)
    parser.add_argument("--restic-cache-dir", required=True)
    parser.add_argument("--retry-lock", default="5m")
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def read_secret(path: str) -> str:
    return Path(path).read_text(encoding="utf-8").strip()


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        handle.write(content)
        tmp_name = handle.name
    os.chmod(tmp_name, 0o644)
    os.replace(tmp_name, path)


def run_json(command: list[str], env: dict[str, str]) -> tuple[dict[str, Any], int]:
    proc = subprocess.run(command, check=False, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        return {}, proc.returncode
    try:
        return json.loads(proc.stdout), 0
    except json.JSONDecodeError:
        return {}, 1


def failed_entry(
    previous: dict[str, Any], now: float, duration: float, exit_code: int
) -> dict[str, Any]:
    entry = dict(previous)
    entry["last_run_timestamp_seconds"] = now
    entry["last_duration_seconds"] = duration
    entry["last_success"] = 0
    entry["exit_code"] = exit_code
    return entry


def collect_bucket(
    bucket: str,
    previous: dict[str, Any],
    args: argparse.Namespace,
    b2_env: dict[str, str],
) -> dict[str, Any]:
    now = time.time()
    start = time.monotonic()
    data, exit_code = run_json(
        [args.b2_cli, "bucket", "get", "--show-size", bucket],
        b2_env,
    )
    duration = time.monotonic() - start
    if exit_code != 0:
        entry = failed_entry(previous, now, duration, exit_code)
        entry.setdefault("total_size_bytes", 0)
        entry.setdefault("file_count", 0)
        entry.setdefault("last_success_timestamp_seconds", 0)
        return entry

    return {
        "total_size_bytes": int(data.get("totalSize", 0)),
        "file_count": int(data.get("fileCount", 0)),
        "last_run_timestamp_seconds": now,
        "last_success_timestamp_seconds": now,
        "last_duration_seconds": duration,
        "last_success": 1,
        "exit_code": 0,
    }


def collect_repository(
    repository: dict[str, str],
    previous: dict[str, Any],
    args: argparse.Namespace,
    restic_env: dict[str, str],
) -> dict[str, Any]:
    now = time.time()
    start = time.monotonic()
    data, exit_code = run_json(
        [
            args.restic,
            "-r",
            repository["repository"],
            "--password-file",
            repository["passwordFile"],
            "--cache-dir",
            args.restic_cache_dir,
            "--retry-lock",
            args.retry_lock,
            "stats",
            "--mode",
            "raw-data",
            "--json",
        ],
        restic_env,
    )
    duration = time.monotonic() - start
    if exit_code != 0:
        entry = failed_entry(previous, now, duration, exit_code)
        entry.setdefault("total_size_bytes", 0)
        entry.setdefault("total_uncompressed_size_bytes", 0)
        entry.setdefault("total_blob_count", 0)
        entry.setdefault("snapshots_count", 0)
        entry.setdefault("last_success_timestamp_seconds", 0)
        return entry

    return {
        "total_size_bytes": int(data.get("total_size", 0)),
        "total_uncompressed_size_bytes": int(data.get("total_uncompressed_size", 0)),
        "total_blob_count": int(data.get("total_blob_count", 0)),
        "snapshots_count": int(data.get("snapshots_count", 0)),
        "last_run_timestamp_seconds": now,
        "last_success_timestamp_seconds": now,
        "last_duration_seconds": duration,
        "last_success": 1,
        "exit_code": 0,
    }


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def labels_text(labels: dict[str, str]) -> str:
    return ",".join(
        f'{name}="{escape_label(str(labels[name]))}"' for name in sorted(labels)
    )


def sample(name: str, labels: dict[str, str], value: int | float) -> str:
    return f"{name}{{{labels_text(labels)}}} {value}"


def result_sample(name: str, labels: dict[str, str], entry: dict[str, Any]) -> str:
    result_labels = labels | {
        "collector_result": "success"
        if int(entry.get("last_success", 0)) == 1
        else "failed",
        "exit_code": str(entry.get("exit_code", "unknown")),
    }
    return sample(name, result_labels, 1)


def build_metrics(
    config: dict[str, Any],
    bucket_state: dict[str, dict[str, Any]],
    repository_state: dict[str, dict[str, Any]],
) -> str:
    lines = [
        "# HELP host_observability_b2_bucket_total_size_bytes Aggregate B2 bucket size in bytes from backblaze-b2 bucket get --show-size, including hidden file versions.",
        "# TYPE host_observability_b2_bucket_total_size_bytes gauge",
        "# HELP host_observability_b2_bucket_files Aggregate B2 bucket file/version count from backblaze-b2 bucket get --show-size.",
        "# TYPE host_observability_b2_bucket_files gauge",
        "# HELP host_observability_b2_bucket_usage_last_run_timestamp_seconds Unix timestamp of the most recent B2 bucket usage collection attempt.",
        "# TYPE host_observability_b2_bucket_usage_last_run_timestamp_seconds gauge",
        "# HELP host_observability_b2_bucket_usage_last_success_timestamp_seconds Unix timestamp of the most recent successful B2 bucket usage collection.",
        "# TYPE host_observability_b2_bucket_usage_last_success_timestamp_seconds gauge",
        "# HELP host_observability_b2_bucket_usage_last_duration_seconds Duration of the most recent B2 bucket usage collection attempt.",
        "# TYPE host_observability_b2_bucket_usage_last_duration_seconds gauge",
        "# HELP host_observability_b2_bucket_usage_last_success Whether the most recent B2 bucket usage collection succeeded.",
        "# TYPE host_observability_b2_bucket_usage_last_success gauge",
        "# HELP host_observability_b2_bucket_usage_last_result_info Metadata about the most recent B2 bucket usage collection result.",
        "# TYPE host_observability_b2_bucket_usage_last_result_info gauge",
        "# HELP host_observability_restic_cloud_repository_total_size_bytes Restic raw-data size for the cloud repository in bytes.",
        "# TYPE host_observability_restic_cloud_repository_total_size_bytes gauge",
        "# HELP host_observability_restic_cloud_repository_total_uncompressed_size_bytes Restic raw-data uncompressed size for the cloud repository in bytes.",
        "# TYPE host_observability_restic_cloud_repository_total_uncompressed_size_bytes gauge",
        "# HELP host_observability_restic_cloud_repository_blobs Restic raw-data blob count for the cloud repository.",
        "# TYPE host_observability_restic_cloud_repository_blobs gauge",
        "# HELP host_observability_restic_cloud_repository_snapshots Snapshot count reported by restic stats for the cloud repository.",
        "# TYPE host_observability_restic_cloud_repository_snapshots gauge",
        "# HELP host_observability_restic_cloud_repository_stats_last_run_timestamp_seconds Unix timestamp of the most recent restic cloud repository stats collection attempt.",
        "# TYPE host_observability_restic_cloud_repository_stats_last_run_timestamp_seconds gauge",
        "# HELP host_observability_restic_cloud_repository_stats_last_success_timestamp_seconds Unix timestamp of the most recent successful restic cloud repository stats collection.",
        "# TYPE host_observability_restic_cloud_repository_stats_last_success_timestamp_seconds gauge",
        "# HELP host_observability_restic_cloud_repository_stats_last_duration_seconds Duration of the most recent restic cloud repository stats collection attempt.",
        "# TYPE host_observability_restic_cloud_repository_stats_last_duration_seconds gauge",
        "# HELP host_observability_restic_cloud_repository_stats_last_success Whether the most recent restic cloud repository stats collection succeeded.",
        "# TYPE host_observability_restic_cloud_repository_stats_last_success gauge",
        "# HELP host_observability_restic_cloud_repository_stats_last_result_info Metadata about the most recent restic cloud repository stats collection result.",
        "# TYPE host_observability_restic_cloud_repository_stats_last_result_info gauge",
    ]

    for bucket in config["buckets"]:
        entry = bucket_state[bucket]
        labels = {"bucket": bucket}
        lines.extend(
            [
                sample(
                    "host_observability_b2_bucket_total_size_bytes",
                    labels,
                    entry["total_size_bytes"],
                ),
                sample(
                    "host_observability_b2_bucket_files", labels, entry["file_count"]
                ),
                sample(
                    "host_observability_b2_bucket_usage_last_run_timestamp_seconds",
                    labels,
                    entry["last_run_timestamp_seconds"],
                ),
                sample(
                    "host_observability_b2_bucket_usage_last_success_timestamp_seconds",
                    labels,
                    entry["last_success_timestamp_seconds"],
                ),
                sample(
                    "host_observability_b2_bucket_usage_last_duration_seconds",
                    labels,
                    entry["last_duration_seconds"],
                ),
                sample(
                    "host_observability_b2_bucket_usage_last_success",
                    labels,
                    entry["last_success"],
                ),
                result_sample(
                    "host_observability_b2_bucket_usage_last_result_info", labels, entry
                ),
            ]
        )

    for repository in config["repositories"]:
        name = repository["name"]
        entry = repository_state[name]
        labels = {
            "backup_job": repository["backupJob"],
            "backup_title": repository["backupTitle"],
            "bucket": repository["bucket"],
            "prefix": repository["prefix"],
            "repository": repository["repository"],
            "source_host": name,
        }
        lines.extend(
            [
                sample(
                    "host_observability_restic_cloud_repository_total_size_bytes",
                    labels,
                    entry["total_size_bytes"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_total_uncompressed_size_bytes",
                    labels,
                    entry["total_uncompressed_size_bytes"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_blobs",
                    labels,
                    entry["total_blob_count"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_snapshots",
                    labels,
                    entry["snapshots_count"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_stats_last_run_timestamp_seconds",
                    labels,
                    entry["last_run_timestamp_seconds"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_stats_last_success_timestamp_seconds",
                    labels,
                    entry["last_success_timestamp_seconds"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_stats_last_duration_seconds",
                    labels,
                    entry["last_duration_seconds"],
                ),
                sample(
                    "host_observability_restic_cloud_repository_stats_last_success",
                    labels,
                    entry["last_success"],
                ),
                result_sample(
                    "host_observability_restic_cloud_repository_stats_last_result_info",
                    labels,
                    entry,
                ),
            ]
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    config = read_json(Path(args.config))
    state_path = Path(args.state_file)
    metrics_path = Path(args.metrics_file)
    previous = read_json(state_path)

    application_key_id = read_secret(config["b2ApplicationKeyIdFile"])
    application_key = read_secret(config["b2ApplicationKeyFile"])

    b2_env = os.environ.copy()
    b2_env.update(
        {
            "B2_APPLICATION_KEY_ID": application_key_id,
            "B2_APPLICATION_KEY": application_key,
            "B2_ACCOUNT_INFO": args.b2_account_info_file,
            "B2_ESCAPE_CONTROL_CHARACTERS": "0",
        }
    )

    restic_env = os.environ.copy()
    restic_env.update(
        {
            "B2_ACCOUNT_ID": application_key_id,
            "B2_ACCOUNT_KEY": application_key,
            "RESTIC_CACHE_DIR": args.restic_cache_dir,
        }
    )

    bucket_state = {}
    previous_buckets = previous.get("buckets", {})
    for bucket in config["buckets"]:
        bucket_state[bucket] = collect_bucket(
            bucket,
            previous_buckets.get(bucket, {}),
            args,
            b2_env,
        )

    repository_state = {}
    previous_repositories = previous.get("repositories", {})
    for repository in config["repositories"]:
        name = repository["name"]
        repository_state[name] = collect_repository(
            repository,
            previous_repositories.get(name, {}),
            args,
            restic_env,
        )

    state = {
        "buckets": bucket_state,
        "repositories": repository_state,
    }
    write_atomic(state_path, json.dumps(state, indent=2, sort_keys=True) + "\n")
    write_atomic(metrics_path, build_metrics(config, bucket_state, repository_state))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
