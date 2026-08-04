from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .policy import PolicyState


PREFIX = "host_observability_adaptive_upload"


def render_metrics_text(state: PolicyState) -> str:
    registry = CollectorRegistry()

    def gauge(name: str, documentation: str, value: float) -> None:
        Gauge(f"{PREFIX}_{name}", documentation, registry=registry).set(value)

    pending_target = state.relaxation_pending_target_mbit

    gauge(
        "target_mbit",
        "Effective adaptive WireGuard upload cap in megabits per second.",
        state.target_mbit,
    )
    gauge(
        "observed_target_mbit",
        "Most recently observed adaptive upload cap before hysteresis in megabits per second.",
        state.observed_target_mbit,
    )
    gauge(
        "reserved_external_media_bandwidth_mbit",
        "External media bitrate reserved by the adaptive upload controller in megabits per second.",
        state.reserved_external_media_bandwidth_mbit or 0,
    )
    gauge(
        "transmission_upload_limit_bytes_per_second",
        "Effective Transmission session upload cap derived from the adaptive upload controller.",
        state.transmission_upload_limit_kbps * 1000,
    )
    gauge(
        "active_external_media_streams",
        "Active external Jellyfin media streams counted by the controller.",
        state.active_external_media_streams or 0,
    )
    gauge(
        "active_media_streams_total",
        "Total active Jellyfin media streams counted by the controller.",
        state.active_media_streams_total or 0,
    )
    gauge(
        "missing_external_media_bitrate_sessions",
        "Active external Jellyfin sessions missing bitrate data.",
        state.missing_external_media_bitrate_sessions or 0,
    )
    gauge(
        "external_media_bitrate_bits_per_second",
        "Summed active external Jellyfin media bitrate seen by the controller in bits per second.",
        state.active_external_media_bitrate_bits_per_second or 0,
    )
    gauge(
        "exporter_ok",
        "Whether the Jellyfin exporter fetch succeeded for the current controller state.",
        1 if state.exporter_ok else 0,
    )
    gauge(
        "relaxation_pending",
        "Whether a more generous observed target is waiting out the relaxation hold timer.",
        1 if pending_target is not None else 0,
    )
    gauge(
        "relaxation_pending_target_mbit",
        "Pending relaxed adaptive upload cap in megabits per second.",
        pending_target or 0,
    )
    return bytes(generate_latest(registry)).decode()
