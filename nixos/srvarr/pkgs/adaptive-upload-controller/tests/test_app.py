import argparse
import datetime
import json
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from prometheus_client.parser import text_string_to_metric_families

from adaptive_upload_controller import app
from adaptive_upload_controller.jellyfin import (
    DEFAULT_MEDIA_TYPES,
    MediaStreamStats,
    collect_media_stream_stats,
    is_internal_remote_endpoint,
)
from adaptive_upload_controller.metrics import render_metrics_text


def policy_args(**overrides):
    values = {
        "exporter_url": "",
        "request_timeout_seconds": 2.0,
        "ca_file": "",
        "client_cert_file": "",
        "client_key_file": "",
        "media_types": sorted(DEFAULT_MEDIA_TYPES),
        "no_streams_mbit": 25.0,
        "minimum_streams_mbit": 0.5,
        "fallback_mbit": 8.0,
        "stream_bitrate_headroom_fraction": 0.1,
        "relaxation_hold_seconds": 90.0,
        "transmission_headroom_fraction": 0.95,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


@contextmanager
def metrics_server(content):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            del format, args

        def do_GET(self):
            body = content["value"].encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}/metrics"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def jellyfin_session(*, user, address, media_type="Video", bitrate=None):
    labels = f'user_id="{user}",username="{user}",device="tv",type="{media_type}"'
    lines = [
        f'jellyfin_user_active{{user_id="{user}",username="{user}",device="tv",ip_address="{address}"}} 1',
        f"jellyfin_now_playing_state{{{labels}}} 1",
    ]
    if bitrate is not None:
        lines.append(f"jellyfin_now_playing_bitrate_bits_per_second{{{labels}}} {bitrate}")
    return "\n".join(lines)


def metric_value(text, name, labels=None):
    expected_labels = labels or {}
    for family in text_string_to_metric_families(text):
        for sample in family.samples:
            if sample.name == name and sample.labels == expected_labels:
                return sample.value
    raise AssertionError(f"missing metric {name} with labels {expected_labels}")


def test_collects_only_external_playing_media_bitrate():
    metrics = "\n".join(
        [
            jellyfin_session(user="external", address="8.8.8.8", bitrate=4_000_000),
            jellyfin_session(user="internal", address="10.0.0.5", bitrate=3_000_000),
            jellyfin_session(user="book", address="8.8.4.4", media_type="Book", bitrate=1_000_000),
        ]
    )

    assert collect_media_stream_stats(metrics, DEFAULT_MEDIA_TYPES) == MediaStreamStats(
        total=2,
        external=1,
        external_bitrate_bps=4_000_000,
        external_missing_bitrate=0,
    )


def test_missing_external_bitrate_uses_minimum_target():
    state = app.observed_policy_state_from_stream_stats(
        args=policy_args(),
        total_media_streams=2,
        active_external_media_streams=1,
        active_external_media_bitrate_bits_per_second=0,
        missing_external_media_bitrate_sessions=1,
    )

    assert state["target_mbit"] == 0.5
    assert state["reason"] == "active_media_streams_missing_bitrate"


def test_policy_relaxes_only_after_stable_hold(tmp_path):
    content = {"value": jellyfin_session(user="external", address="8.8.8.8", bitrate=4_000_000)}
    state_file = tmp_path / "state.json"

    with metrics_server(content) as url:
        args = policy_args(exporter_url=url)
        constrained = app.decide_effective_policy_state(args, state_file)
        assert constrained["target_mbit"] == 20.6
        app.write_json_atomic(state_file, constrained)

        content["value"] = ""
        holding = app.decide_effective_policy_state(args, state_file)
        assert holding["target_mbit"] == 20.6
        assert holding["observed_target_mbit"] == 25.0
        assert holding["relaxation_pending_target_mbit"] == 25.0

        holding["relaxation_pending_since"] = app.datetime_to_utc_iso8601(
            datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=2)
        )
        app.write_json_atomic(state_file, holding)
        relaxed = app.decide_effective_policy_state(args, state_file)

    assert relaxed["target_mbit"] == 25.0
    assert relaxed["relaxation_pending_target_mbit"] is None


def test_unreachable_exporter_uses_conservative_fallback():
    state = app.decide_observed_policy_state(policy_args(exporter_url="http://127.0.0.1:1/metrics"))

    assert state["target_mbit"] == 8.0
    assert state["reason"] == "exporter_unreachable"
    assert state["exporter_ok"] is False


def test_stale_or_invalid_state_uses_safe_policy(tmp_path):
    missing = app.load_policy_state(
        tmp_path / "missing.json",
        fallback_mbit=8.0,
        transmission_headroom_fraction=0.95,
        max_state_age_seconds=90.0,
    )
    assert missing["reason"] == "missing_or_invalid_state_file"
    assert missing["transmission_upload_limit_kbps"] == 950

    stale_path = tmp_path / "stale.json"
    stale = app.default_policy_state(12.0, 0.95, "current", True, 0)
    stale["updated_at"] = "2000-01-01T00:00:00Z"
    app.write_json_atomic(stale_path, stale)
    loaded = app.load_policy_state(stale_path, 8.0, 0.95, 90.0)
    assert loaded["reason"] == "stale_state_file"
    assert loaded["target_mbit"] == 8.0

    stale_path.write_text(json.dumps({"target_mbit": "bad"}), encoding="utf-8")
    invalid = app.load_policy_state(stale_path, 8.0, 0.95, None)
    assert invalid["reason"] == "missing_or_invalid_state_file"


def test_metrics_render_current_policy_values():
    state = app.default_policy_state(8.0, 0.95, "fallback", False, 2)
    state.update(
        observed_target_mbit=7.0,
        reserved_external_media_bandwidth_mbit=3.5,
        missing_external_media_bitrate_sessions=1,
        active_external_media_bitrate_bits_per_second=4_000_000,
        relaxation_pending_target_mbit=12.0,
    )

    metrics = render_metrics_text(state)
    assert metric_value(metrics, "host_observability_adaptive_upload_target_mbit") == 8.0
    assert (
        metric_value(
            metrics,
            "host_observability_adaptive_upload_transmission_upload_limit_bytes_per_second",
        )
        == 950_000
    )
    assert metric_value(metrics, "host_observability_adaptive_upload_relaxation_pending") == 1


def test_endpoint_and_transmission_value_normalization():
    assert is_internal_remote_endpoint("[fd00::1]:8096")
    assert is_internal_remote_endpoint("192.168.1.5:8096")
    assert not is_internal_remote_endpoint("8.8.8.8:8096")
    assert not is_internal_remote_endpoint("not-an-address")

    assert app.transmission_get_current_upload_limit_kbps({"speed_limit_up": 123}) == 123
    assert app.transmission_get_current_upload_limit_kbps({"speed_limit_up": "123"}) is None
    assert app.transmission_get_current_upload_limit_enabled({"speed_limit_up_enabled": True})
