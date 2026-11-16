import json
import subprocess
import sys

import pytest
from cake_metrics.cli import main
from cake_metrics.collector import collect
from cake_metrics.models import Target
from cake_metrics.source import CommandRunner, TcSource
from prometheus_client.parser import text_string_to_metric_families

TARGET = Target(profile="vpn", limit="download", direction="ingress", device="ifb0", parent="root")


def queue(handle="8001:", **changes):
    return {
        "kind": "cake",
        "handle": handle,
        "root": True,
        "options": {"bandwidth": 1250000},
        "bytes": 12345,
        "packets": 90,
        "drops": 10,
        "backlog": 1200,
        "qlen": 1,
        "tins": [
            {
                "avg_delay_us": 500,
                "peak_delay_us": 1000,
                "base_delay_us": 100,
                "sparse_flows": 1,
                "bulk_flows": 1,
                "unresponsive_flows": 1,
                "ecn_mark": 3,
            }
        ],
        **changes,
    }


def flow(handle="8001:1", **changes):
    return {
        "parent": "8001:",
        "handle": handle,
        "stats": {"blue_prob": 2**31, "count": 25, "backlog": 0, **changes},
    }


class SnapshotRunner:
    def __init__(self, queues=None, flows=None):
        self.queues = [queue()] if queues is None else queues
        self.flows = [flow()] if flows is None else flows

    def run(self, arguments):
        return json.dumps(self.queues if "qdisc" in arguments else self.flows)


def samples(path):
    return {
        sample.name: sample.value
        for family in text_string_to_metric_families(path.read_text())
        for sample in family.samples
    }


def test_exports_queue_and_aggregates_flows_without_flow_labels(tmp_path):
    output = tmp_path / "cake.prom"
    runner = SnapshotRunner(
        flows=[flow(), flow("8001:2", blue_prob=0, dropping=True, backlog=1200)]
    )
    assert collect(TcSource(runner), [TARGET], output)
    values = samples(output)
    prefix = "host_observability_cake_"
    assert values[prefix + "rate_bits_per_second"] == 10_000_000
    assert values[prefix + "blue_probability_max"] == 0.5
    assert values[prefix + "blue_empty_flows"] == 1
    assert values[prefix + "codel_dropping_flows"] == 1
    assert values[prefix + "delay_average_seconds"] == 0.0005
    assert values[prefix + "dropped_packets_total"] == 10
    assert values[prefix + "ecn_marks_total"] == 3
    assert values[prefix + "collection_success"] == 1
    assert output.stat().st_mode & 0o777 == 0o644
    assert "8001" not in output.read_text()


def test_matches_cake_under_htb_and_excludes_other_classes():
    target = TARGET.model_copy(update={"parent": "1:10", "direction": "egress"})
    runner = SnapshotRunner(
        queues=[
            {"kind": "htb"},
            queue(root=False, parent="1:10"),
            queue("20:", root=False, parent="1:20"),
        ],
        flows=[flow(), {"parent": "20:", "stats": {}}],
    )
    selected, flows = TcSource(runner).read(target)
    assert selected.parent == "1:10"
    assert len(flows) == 1


def test_idle_recovery_replaces_previous_penalty(tmp_path):
    output = tmp_path / "cake.prom"
    runner = SnapshotRunner()
    source = TcSource(runner)
    assert collect(source, [TARGET], output)
    runner.flows = []
    runner.queues = [queue(backlog=0, qlen=0)]
    assert collect(source, [TARGET], output)
    assert samples(output)["host_observability_cake_blue_probability_max"] == 0


@pytest.mark.parametrize(
    "runner",
    [
        SnapshotRunner(queues=[]),
        SnapshotRunner(queues=[queue(), queue()]),
        SnapshotRunner(queues=[queue(options={})]),
        SnapshotRunner(flows=[flow("8001:401")]),
    ],
)
def test_missing_or_invalid_queue_marks_failure_and_removes_stale_state(tmp_path, runner):
    output = tmp_path / "cake.prom"
    assert collect(TcSource(SnapshotRunner()), [TARGET], output)
    assert not collect(TcSource(runner), [TARGET], output)
    values = samples(output)
    assert values["host_observability_cake_collection_success"] == 0
    assert "host_observability_cake_blue_probability_max" not in values


def test_cli_reads_config_and_writes_metrics(tmp_path):
    config = tmp_path / "config.json"
    output = tmp_path / "cake.prom"
    config.write_text(json.dumps([TARGET.model_dump()]))
    assert main(["--config", str(config), "--output", str(output)], TcSource(SnapshotRunner())) == 0
    assert (
        main(
            ["--config", str(config), "--output", str(output)], TcSource(SnapshotRunner(queues=[]))
        )
        == 1
    )


def test_command_runner_reads_output_and_reports_failure():
    runner = CommandRunner()
    assert runner.run([sys.executable, "-c", "print('ok')"]).strip() == "ok"
    with pytest.raises(subprocess.CalledProcessError):
        runner.run([sys.executable, "-c", "raise SystemExit(1)"])


def test_tins_are_aggregated_separately(tmp_path):
    output = tmp_path / "cake.prom"
    runner = SnapshotRunner(
        queues=[queue(tins=queue()["tins"] * 2)],
        flows=[flow(), flow("8001:401", blue_prob=2**30)],
    )
    assert collect(TcSource(runner), [TARGET], output)
    values = {
        sample.labels["tin"]: sample.value
        for family in text_string_to_metric_families(output.read_text())
        for sample in family.samples
        if sample.name == "host_observability_cake_blue_probability_max"
    }
    assert values == {"0": 0.5, "1": 0.25}


def test_failed_command_still_publishes_health(tmp_path):
    class UnavailableRunner:
        def run(self, arguments):
            raise subprocess.TimeoutExpired("tc", 2)

    output = tmp_path / "cake.prom"
    assert not collect(TcSource(UnavailableRunner()), [TARGET], output)
    assert samples(output)["host_observability_cake_collection_success"] == 0
