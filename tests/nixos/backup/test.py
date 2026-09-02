# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.

import json


def snapshot_count():
    return len(json.loads(client.succeed("restic-server snapshots --json")))


def cloud_snapshot_count():
    command = (
        f"AWS_ACCESS_KEY_ID={S3_ACCESS_KEY} "
        f"AWS_SECRET_ACCESS_KEY={S3_SECRET_KEY} "
        f"restic -r {CLOUD_REPOSITORY} "
        "--password-file /run/secrets/backup/restic/client/cloud/password "
        "snapshots --json"
    )
    return len(json.loads(server.succeed(command)))


def assert_metric(machine, file_name, metric, value):
    metrics = machine.succeed(f"cat /var/lib/prometheus-node-exporter-textfile/{file_name}")
    matches = [line for line in metrics.splitlines() if line.startswith(metric + "{")]
    assert len(matches) == 1, (metric, metrics)
    assert matches[0].endswith(f" {value}"), matches[0]
    return metrics


start_all()
server.wait_for_unit("sshd.service")
server.wait_for_unit("garage.service")
server.wait_for_open_port(3901)
garage_node_id = server.succeed("garage status | tail -n1 | awk '{ print $1 }'")
server.succeed(
    f"garage layout assign -c 100MB -z test {garage_node_id}",
    "garage layout apply --version 1",
    f"garage key import {S3_ACCESS_KEY} {S3_SECRET_KEY} --yes",
    "garage bucket create backups",
    f"garage bucket allow --read --write --owner backups --key {S3_ACCESS_KEY}",
)
server.wait_for_open_port(9000)
client.wait_for_unit("multi-user.target")
client.wait_for_unit("backup-metrics-configured.service")
client.succeed("printf 'first version\\n' > /var/lib/backup-test/source.txt")

with subtest("only the complete pipeline has a timer"):
    client.succeed("systemctl cat restic-backups-server.timer")
    client.fail("systemctl cat prepare-backup-test.timer")
    server.succeed("systemctl cat restic-client-cloud-offload.timer")
    server.succeed("systemctl cat restic-client-cloud-prune.timer")
    server.fail("systemctl cat restic-cloud-usage-export.timer")

with subtest("pipeline prepares and snapshots once"):
    client.succeed("systemctl start restic-backups-server.service")
    assert client.succeed("cat /var/lib/backup-test/preparation-count").strip() == "1"
    assert snapshot_count() == 1
    assert_metric(
        client,
        "prepare-backup-test.prom",
        "host_observability_backup_last_success",
        "1.0",
    )
    assert_metric(
        client,
        "restic-server.prom",
        "host_observability_backup_last_success",
        "1.0",
    )

with subtest("server offloads the repository"):
    server.succeed("systemctl start restic-client-cloud-offload.service")
    assert cloud_snapshot_count() == 1
    metrics = assert_metric(
        server,
        "restic-client-cloud-offload.prom",
        "host_observability_backup_last_success",
        "1.0",
    )
    assert 'backup_job="restic-client-cloud-offload"' in metrics

with subtest("server prunes the cloud repository separately"):
    server.succeed("systemctl start restic-client-cloud-prune.service")

with subtest("snapshot restores the prepared content"):
    client.succeed("rm -rf /tmp/restore")
    client.succeed("restic-server restore latest --target /tmp/restore")
    restored = client.succeed("cat /tmp/restore/var/lib/backup-test/staged/source.txt")
    assert restored.strip() == "first version", restored

with subtest("failed preparation blocks a new snapshot"):
    client.succeed("touch /run/fail-backup-preparation")
    client.fail("systemctl start restic-backups-server.service")
    assert snapshot_count() == 1
    assert_metric(
        client,
        "prepare-backup-test.prom",
        "host_observability_backup_last_success",
        "0.0",
    )

with subtest("SFTP account cannot execute commands"):
    client.fail("ssh restic-client@restic-backup-server true")
