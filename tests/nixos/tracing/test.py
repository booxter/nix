# ruff: noqa: F821
# The NixOS test driver provides machine and subtest.

import json

machine.start()
machine.wait_for_unit("tempo.service")
machine.wait_for_unit("alloy.service")
machine.wait_for_unit("nginx.service")
machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/ready")
machine.wait_until_succeeds("curl -fsS http://127.0.0.1:12345/-/ready")

with subtest("remote ingestion requires a client certificate"):
    machine.fail("curl -kfsS -X POST https://tempo.test/v1/traces -d '{}'")

with subtest("unrelated users cannot connect to the local collector"):
    machine.fail(
        "runuser -u nobody -- python -c "
        "'import socket; socket.socket(socket.AF_UNIX).connect(\"/run/alloy-otlp/otlp.sock\")'"
    )


def check_helper_trace(trace_id):
    # A rejected request still produces an error span inside the real sandbox.
    logs = machine.fail(
        "echo '{}' | runuser -u media-repair-worker -- /etc/trace-helper "
        "--operation transform --timeout 1s --media-timeout 5s "
        "--trace-endpoint unix:///run/alloy-otlp/otlp.sock "
        f"--traceparent 00-{trace_id}-0123456789abcdef-01 2>&1"
    )
    assert "job and attempt must be positive" in logs, logs
    query = f"curl -fsS -H 'Accept: application/json' http://127.0.0.1:3200/api/traces/{trace_id}"
    machine.wait_until_succeeds(query, timeout=30)
    result = json.loads(machine.succeed(query))
    spans = []
    for batch in result["batches"]:
        for scope in batch["scopeSpans"]:
            spans.extend(scope["spans"])
    helper = next(span for span in spans if span["name"] == "helper transform")
    assert helper["parentSpanId"] == "ASNFZ4mrze8=", helper
    assert helper["status"]["code"] == "STATUS_CODE_ERROR", helper


with subtest("isolated helper exports through Alloy and mTLS into Tempo"):
    check_helper_trace("0123456789abcdef0123456789abcdef")

with subtest("Alloy restart preserves the mounted directory and accepts new spans"):
    directory_inode = machine.succeed("stat -c %i /run/alloy-otlp")
    machine.succeed("systemctl restart alloy.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:12345/-/ready")
    assert machine.succeed("stat -c %i /run/alloy-otlp") == directory_inode
    check_helper_trace("abcdef0123456789abcdef0123456789")

with subtest("collector exposes export health"):
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:12345/metrics | grep otelcol_exporter_sent_spans_total"
    )
