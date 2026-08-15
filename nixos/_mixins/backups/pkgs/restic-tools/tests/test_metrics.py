from prometheus_client.parser import text_string_to_metric_families

from restic_tools.metrics import render_metrics
from restic_tools.models import BucketState, ExporterState, RepositoryState

from .test_collector import config


def samples() -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    rendered = render_metrics(
        config(),
        ExporterState(
            buckets={
                "backups": BucketState(
                    total_size_bytes=100,
                    file_count=7,
                    last_success=0,
                    exit_code=5,
                )
            },
            repositories={
                "srvarr": RepositoryState(
                    total_size_bytes=200,
                    total_uncompressed_size_bytes=300,
                    total_blob_count=8,
                    snapshots_count=9,
                    last_success=1,
                )
            },
        ),
    )
    return {
        (sample.name, tuple(sorted(sample.labels.items()))): sample.value
        for family in text_string_to_metric_families(rendered)
        for sample in family.samples
    }


def test_metrics_preserve_names_values_and_result_labels() -> None:
    exported = samples()

    assert (
        exported[("host_observability_b2_bucket_total_size_bytes", (("bucket", "backups"),))] == 100
    )
    assert (
        exported[
            (
                "host_observability_b2_bucket_usage_last_result_info",
                (
                    ("bucket", "backups"),
                    ("collector_result", "failed"),
                    ("exit_code", "5"),
                ),
            )
        ]
        == 1
    )
    repository_labels = (
        ("backup_job", "restic-srvarr-cloud-offload"),
        ("backup_title", "srvarr Cloud Offload"),
        ("bucket", "backups"),
        ("prefix", "hosts/srvarr"),
        ("repository", "b2:backups:hosts/srvarr"),
        ("source_host", "srvarr"),
    )
    assert (
        exported[("host_observability_restic_cloud_repository_total_size_bytes", repository_labels)]
        == 200
    )
