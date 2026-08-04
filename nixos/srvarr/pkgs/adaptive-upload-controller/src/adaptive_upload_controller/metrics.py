from collections.abc import Mapping
import math

from prometheus_client import CollectorRegistry, Gauge, generate_latest


PREFIX = "host_observability_adaptive_upload"


def nonnegative_int(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def nonnegative_float(value: object) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or float(value) < 0
    ):
        return 0.0
    return float(value)


def render_metrics_text(state: Mapping[str, object]) -> str:
    registry = CollectorRegistry()

    def gauge(name: str, documentation: str, value: float) -> None:
        Gauge(f"{PREFIX}_{name}", documentation, registry=registry).set(value)

    transmission_limit = nonnegative_int(state.get("transmission_upload_limit_kbps"))
    pending_target = state.get("relaxation_pending_target_mbit")
    pending = (
        isinstance(pending_target, (int, float))
        and not isinstance(pending_target, bool)
        and math.isfinite(float(pending_target))
    )

    gauge(
        "target_mbit",
        "Effective adaptive WireGuard upload cap in megabits per second.",
        nonnegative_float(state.get("target_mbit")),
    )
    gauge(
        "observed_target_mbit",
        "Most recently observed adaptive upload cap before hysteresis in megabits per second.",
        nonnegative_float(state.get("observed_target_mbit")),
    )
    gauge(
        "reserved_external_media_bandwidth_mbit",
        "External media bitrate reserved by the adaptive upload controller in megabits per second.",
        nonnegative_float(state.get("reserved_external_media_bandwidth_mbit")),
    )
    gauge(
        "transmission_upload_limit_bytes_per_second",
        "Effective Transmission session upload cap derived from the adaptive upload controller.",
        transmission_limit * 1000,
    )
    gauge(
        "active_external_media_streams",
        "Active external Jellyfin media streams counted by the controller.",
        nonnegative_int(state.get("active_external_media_streams")),
    )
    gauge(
        "active_media_streams_total",
        "Total active Jellyfin media streams counted by the controller.",
        nonnegative_int(state.get("active_media_streams_total")),
    )
    gauge(
        "missing_external_media_bitrate_sessions",
        "Active external Jellyfin sessions missing bitrate data.",
        nonnegative_int(state.get("missing_external_media_bitrate_sessions")),
    )
    gauge(
        "external_media_bitrate_bits_per_second",
        "Summed active external Jellyfin media bitrate seen by the controller in bits per second.",
        nonnegative_int(state.get("active_external_media_bitrate_bits_per_second")),
    )
    gauge(
        "exporter_ok",
        "Whether the Jellyfin exporter fetch succeeded for the current controller state.",
        1 if state.get("exporter_ok") else 0,
    )
    gauge(
        "relaxation_pending",
        "Whether a more generous observed target is waiting out the relaxation hold timer.",
        1 if pending else 0,
    )
    gauge(
        "relaxation_pending_target_mbit",
        "Pending relaxed adaptive upload cap in megabits per second.",
        nonnegative_float(pending_target),
    )
    return generate_latest(registry).decode()
