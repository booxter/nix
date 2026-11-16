# ruff: noqa: F821
# The NixOS test driver provides machine and subtest.

import json
import shlex
import time

machine.start()
machine.wait_for_unit("tempo.service")
machine.wait_for_unit("alloy.service")
machine.wait_for_unit("nginx.service")
machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/ready")
machine.wait_until_succeeds("curl -fsS http://127.0.0.1:12345/-/ready")

with subtest("ingestion requires a client certificate"):
    machine.fail("curl -kfsS -X POST https://tempo.test/v1/traces -d '{}'")

trace_id = "0123456789abcdef0123456789abcdef"
now = time.time_ns()
payload = {
    "resourceSpans": [
        {
            "resource": {
                "attributes": [{"key": "service.name", "value": {"stringValue": "tracing-test"}}]
            },
            "scopeSpans": [
                {
                    "spans": [
                        {
                            "traceId": trace_id,
                            "spanId": "0123456789abcdef",
                            "name": "synthetic-repair",
                            "startTimeUnixNano": str(now),
                            "endTimeUnixNano": str(now + 1_000_000),
                        }
                    ]
                }
            ],
        }
    ],
}

with subtest("Alloy forwards traces through mTLS into Tempo"):
    machine.succeed(
        "curl -fsS -H 'Content-Type: application/json' "
        "http://127.0.0.1:4318/v1/traces -d " + shlex.quote(json.dumps(payload))
    )
    query = f"curl -fsS -H 'Accept: application/json' http://127.0.0.1:3200/api/traces/{trace_id}"
    machine.wait_until_succeeds(query + " | grep synthetic-repair")
    result = json.loads(machine.succeed(query))
    assert result["batches"][0]["scopeSpans"][0]["spans"][0]["name"] == "synthetic-repair"

with subtest("collector exposes export health"):
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:12345/metrics | grep otelcol_exporter_sent_spans_total"
    )
