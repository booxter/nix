from __future__ import annotations

from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import ExporterConfig, ExporterState


def _gauge(
    registry: CollectorRegistry,
    name: str,
    documentation: str,
    labels: tuple[str, ...],
) -> Gauge:
    return Gauge(name, documentation, labels, registry=registry)


def render_metrics(config: ExporterConfig, state: ExporterState) -> str:
    registry = CollectorRegistry()
    bucket_labels = ("bucket",)
    bucket_metrics = {
        "size": _gauge(
            registry,
            "host_observability_b2_bucket_total_size_bytes",
            "Aggregate B2 bucket size in bytes, including hidden file versions.",
            bucket_labels,
        ),
        "files": _gauge(
            registry,
            "host_observability_b2_bucket_files",
            "Aggregate B2 bucket file/version count.",
            bucket_labels,
        ),
        "run": _gauge(
            registry,
            "host_observability_b2_bucket_usage_last_run_timestamp_seconds",
            "Unix timestamp of the most recent B2 bucket usage collection attempt.",
            bucket_labels,
        ),
        "success_time": _gauge(
            registry,
            "host_observability_b2_bucket_usage_last_success_timestamp_seconds",
            "Unix timestamp of the most recent successful B2 bucket usage collection.",
            bucket_labels,
        ),
        "duration": _gauge(
            registry,
            "host_observability_b2_bucket_usage_last_duration_seconds",
            "Duration of the most recent B2 bucket usage collection attempt.",
            bucket_labels,
        ),
        "success": _gauge(
            registry,
            "host_observability_b2_bucket_usage_last_success",
            "Whether the most recent B2 bucket usage collection succeeded.",
            bucket_labels,
        ),
        "result": _gauge(
            registry,
            "host_observability_b2_bucket_usage_last_result_info",
            "Metadata about the most recent B2 bucket usage collection result.",
            (*bucket_labels, "collector_result", "exit_code"),
        ),
    }
    for bucket in config.buckets:
        bucket_entry = state.buckets[bucket]
        bucket_metrics["size"].labels(bucket).set(bucket_entry.total_size_bytes)
        bucket_metrics["files"].labels(bucket).set(bucket_entry.file_count)
        bucket_metrics["run"].labels(bucket).set(bucket_entry.last_run_timestamp_seconds)
        bucket_metrics["success_time"].labels(bucket).set(
            bucket_entry.last_success_timestamp_seconds
        )
        bucket_metrics["duration"].labels(bucket).set(bucket_entry.last_duration_seconds)
        bucket_metrics["success"].labels(bucket).set(bucket_entry.last_success)
        result = "success" if bucket_entry.last_success else "failed"
        bucket_metrics["result"].labels(bucket, result, str(bucket_entry.exit_code)).set(1)

    repository_labels = (
        "backup_job",
        "backup_title",
        "bucket",
        "prefix",
        "repository",
        "source_host",
    )
    repository_metrics = {
        "size": _gauge(
            registry,
            "host_observability_restic_cloud_repository_total_size_bytes",
            "Restic raw-data size for the cloud repository in bytes.",
            repository_labels,
        ),
        "uncompressed": _gauge(
            registry,
            "host_observability_restic_cloud_repository_total_uncompressed_size_bytes",
            "Restic raw-data uncompressed size for the cloud repository in bytes.",
            repository_labels,
        ),
        "blobs": _gauge(
            registry,
            "host_observability_restic_cloud_repository_blobs",
            "Restic raw-data blob count for the cloud repository.",
            repository_labels,
        ),
        "snapshots": _gauge(
            registry,
            "host_observability_restic_cloud_repository_snapshots",
            "Snapshot count reported by restic stats for the cloud repository.",
            repository_labels,
        ),
        "run": _gauge(
            registry,
            "host_observability_restic_cloud_repository_stats_last_run_timestamp_seconds",
            "Unix timestamp of the most recent repository stats collection attempt.",
            repository_labels,
        ),
        "success_time": _gauge(
            registry,
            "host_observability_restic_cloud_repository_stats_last_success_timestamp_seconds",
            "Unix timestamp of the most recent successful repository stats collection.",
            repository_labels,
        ),
        "duration": _gauge(
            registry,
            "host_observability_restic_cloud_repository_stats_last_duration_seconds",
            "Duration of the most recent repository stats collection attempt.",
            repository_labels,
        ),
        "success": _gauge(
            registry,
            "host_observability_restic_cloud_repository_stats_last_success",
            "Whether the most recent repository stats collection succeeded.",
            repository_labels,
        ),
        "result": _gauge(
            registry,
            "host_observability_restic_cloud_repository_stats_last_result_info",
            "Metadata about the most recent repository stats collection result.",
            (*repository_labels, "collector_result", "exit_code"),
        ),
    }
    for repository in config.repositories:
        repository_entry = state.repositories[repository.name]
        labels = (
            repository.backup_job,
            repository.backup_title,
            repository.bucket,
            repository.prefix,
            repository.repository,
            repository.name,
        )
        repository_metrics["size"].labels(*labels).set(repository_entry.total_size_bytes)
        repository_metrics["uncompressed"].labels(*labels).set(
            repository_entry.total_uncompressed_size_bytes
        )
        repository_metrics["blobs"].labels(*labels).set(repository_entry.total_blob_count)
        repository_metrics["snapshots"].labels(*labels).set(repository_entry.snapshots_count)
        repository_metrics["run"].labels(*labels).set(repository_entry.last_run_timestamp_seconds)
        repository_metrics["success_time"].labels(*labels).set(
            repository_entry.last_success_timestamp_seconds
        )
        repository_metrics["duration"].labels(*labels).set(repository_entry.last_duration_seconds)
        repository_metrics["success"].labels(*labels).set(repository_entry.last_success)
        result = "success" if repository_entry.last_success else "failed"
        repository_metrics["result"].labels(*labels, result, str(repository_entry.exit_code)).set(1)

    return generate_latest(registry).decode()
