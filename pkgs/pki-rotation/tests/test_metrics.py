from prometheus_client.parser import text_string_to_metric_families

from pki_rotation.metrics import certificate_metrics, rotation_metrics
from pki_rotation.models import (
    CertificateCategory,
    CertificateInventory,
    CertificateRecord,
    RotationSummary,
    SourceKind,
)


def sample_values(text: str) -> dict[str, float]:
    return {
        sample.name: sample.value
        for family in text_string_to_metric_families(text)
        for sample in family.samples
    }


def test_certificate_metrics_use_prometheus_client_exposition() -> None:
    inventory = CertificateInventory(
        (
            CertificateRecord(
                host="host",
                category=CertificateCategory.INTERNAL_HTTPS_SERVER,
                cert_name="web",
                source_kind=SourceKind.REPOSITORY_SECRET,
                parse_success=True,
                rotation_due=False,
                common_name='web"name',
                issuer_common_name="issuer",
                not_before_timestamp_seconds=100.0,
                not_after_timestamp_seconds=200.0,
                days_remaining=1.25,
            ),
        )
    )

    text = certificate_metrics(inventory)
    values = sample_values(text)

    assert values["host_observability_pki_cert_expected"] == 1
    assert values["host_observability_pki_cert_parse_success"] == 1
    assert values["host_observability_pki_cert_rotation_due"] == 0
    assert values["host_observability_pki_cert_days_remaining"] == 1.25
    assert 'common_name="web\\"name"' in text


def test_rotation_metrics_preserve_controller_metric_names() -> None:
    text = rotation_metrics(
        RotationSummary(
            success=True,
            dry_run=False,
            branch="ci/pki-rotate",
            base_branch="master",
            run_timestamp_seconds=123.0,
            due_count=2,
            rotated_count=1,
            pr_url="https://github.com/owner/repo/pull/1",
        )
    )
    values = sample_values(text)

    assert values["host_observability_pki_rotation_last_run_timestamp_seconds"] == 123
    assert values["host_observability_pki_rotation_last_success"] == 1
    assert values["host_observability_pki_rotation_last_due_count"] == 2
    assert values["host_observability_pki_rotation_last_rotated_count"] == 1
    assert values["host_observability_pki_rotation_last_pr_open"] == 1
