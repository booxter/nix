from __future__ import annotations

from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import CertificateInventory, RotationSummary


def certificate_metrics(inventory: CertificateInventory) -> str:
    registry = CollectorRegistry()
    labels = ("host", "category", "cert_name")
    expected = Gauge(
        "host_observability_pki_cert_expected",
        "Whether a managed PKI certificate is expected to exist.",
        labels,
        registry=registry,
    )
    parse_success = Gauge(
        "host_observability_pki_cert_parse_success",
        "Whether a managed PKI certificate was present and parsed successfully.",
        labels,
        registry=registry,
    )
    rotation_due = Gauge(
        "host_observability_pki_cert_rotation_due",
        "Whether a managed PKI certificate is inside the configured rotation window.",
        labels,
        registry=registry,
    )
    not_before = Gauge(
        "host_observability_pki_cert_not_before_timestamp_seconds",
        "Not-before timestamp of a managed PKI certificate.",
        labels,
        registry=registry,
    )
    not_after = Gauge(
        "host_observability_pki_cert_not_after_timestamp_seconds",
        "Not-after timestamp of a managed PKI certificate.",
        labels,
        registry=registry,
    )
    days_remaining = Gauge(
        "host_observability_pki_cert_days_remaining",
        "Remaining lifetime of a managed PKI certificate in days.",
        labels,
        registry=registry,
    )
    info = Gauge(
        "host_observability_pki_cert_info",
        "Static metadata about a managed PKI certificate.",
        (*labels, "common_name", "issuer_common_name"),
        registry=registry,
    )
    for record in inventory.root:
        values = (record.host, record.category.value, record.cert_name)
        expected.labels(*values).set(1)
        parse_success.labels(*values).set(record.parse_success)
        rotation_due.labels(*values).set(record.rotation_due)
        if not record.parse_success:
            continue
        assert record.not_before_timestamp_seconds is not None
        assert record.not_after_timestamp_seconds is not None
        assert record.days_remaining is not None
        not_before.labels(*values).set(record.not_before_timestamp_seconds)
        not_after.labels(*values).set(record.not_after_timestamp_seconds)
        days_remaining.labels(*values).set(record.days_remaining)
        info.labels(*values, record.common_name, record.issuer_common_name).set(1)
    return generate_latest(registry).decode()


def rotation_metrics(summary: RotationSummary) -> str:
    registry = CollectorRegistry()
    labels = ("branch", "base_branch")
    values = (summary.branch, summary.base_branch)
    metrics = (
        (
            "host_observability_pki_rotation_last_run_timestamp_seconds",
            "Last completion time of the PKI rotation controller.",
            summary.run_timestamp_seconds,
        ),
        (
            "host_observability_pki_rotation_last_success",
            "Whether the last PKI rotation controller run completed successfully.",
            summary.success,
        ),
        (
            "host_observability_pki_rotation_last_due_count",
            "Number of certificates inside the rotation window on the last controller run.",
            summary.due_count,
        ),
        (
            "host_observability_pki_rotation_last_rotated_count",
            "Number of certificates actually reissued on the last controller run.",
            summary.rotated_count,
        ),
        (
            "host_observability_pki_rotation_last_pr_open",
            "Whether the controller left an open pull request to review.",
            summary.pr_url is not None,
        ),
    )
    for name, documentation, value in metrics:
        Gauge(name, documentation, labels, registry=registry).labels(*values).set(value)
    return generate_latest(registry).decode()
