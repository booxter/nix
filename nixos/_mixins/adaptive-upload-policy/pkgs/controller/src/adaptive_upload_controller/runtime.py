from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import logging
from pathlib import Path
import time

from atomic_file_writes import write_text_atomic
from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
)

from .errors import ControllerError
from .metrics import render_metrics_text
from .policy import (
    DecisionConfig,
    decide_effective_policy,
    load_policy_state,
    save_policy_state,
)
from .traffic_control import TrafficControl


LOG = logging.getLogger("adaptive-upload-controller")


@dataclass(frozen=True)
class DeciderRuntimeConfig:
    decision: DecisionConfig
    state_file: Path
    metrics_file: Path | None
    interval_seconds: float


@dataclass(frozen=True)
class TransmissionRuntimeConfig:
    rpc_url: str
    state_file: Path
    interval_seconds: float
    request_timeout_seconds: float
    fallback_mbit: float
    transmission_headroom_fraction: float
    max_state_age_seconds: float


@dataclass(frozen=True)
class TrafficControlRuntimeConfig:
    state_file: Path
    interval_seconds: float
    fallback_mbit: float
    transmission_headroom_fraction: float
    max_state_age_seconds: float


def transmission_get_current_upload_limit_kbps(
    session_arguments: Mapping[str, object],
) -> int | None:
    value = session_arguments.get("speed_limit_up")
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return None


def transmission_get_current_upload_limit_enabled(
    session_arguments: Mapping[str, object],
) -> bool | None:
    value = session_arguments.get("speed_limit_up_enabled")
    return value if isinstance(value, bool) else None


def run_decider(config: DeciderRuntimeConfig) -> int:
    last_signature: tuple[object, ...] | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = decide_effective_policy(config.decision, config.state_file)
            signature = state.signature()
            save_policy_state(config.state_file, state)
            if config.metrics_file is not None:
                write_text_atomic(
                    config.metrics_file,
                    render_metrics_text(state),
                )
            if signature != last_signature:
                LOG.info(
                    "policy updated: observed_target_mbit=%s target_mbit=%s "
                    "transmission_upload_limit_kbps=%s "
                    "active_external_media_streams=%s "
                    "active_external_media_bitrate_bits_per_second=%s "
                    "active_media_streams_total=%s "
                    "missing_external_media_bitrate_sessions=%s "
                    "reserved_external_media_bandwidth_mbit=%s reason=%s "
                    "observed_reason=%s exporter_ok=%s "
                    "relaxation_pending_target_mbit=%s "
                    "relaxation_pending_since=%s",
                    state.observed_target_mbit,
                    state.target_mbit,
                    state.transmission_upload_limit_kbps,
                    state.active_external_media_streams,
                    state.active_external_media_bitrate_bits_per_second,
                    state.active_media_streams_total,
                    state.missing_external_media_bitrate_sessions,
                    state.reserved_external_media_bandwidth_mbit,
                    state.reason,
                    state.observed_reason,
                    state.exporter_ok,
                    state.relaxation_pending_target_mbit,
                    state.relaxation_pending_since,
                )
                last_signature = signature
        except Exception:
            LOG.exception("failed to refresh adaptive upload policy state")

        sleep_for = max(
            0.0,
            config.interval_seconds - (time.monotonic() - started_at),
        )
        time.sleep(sleep_for)


def run_transmission_applier(config: TransmissionRuntimeConfig) -> int:
    client = TransmissionRpcClient(
        rpc_url=config.rpc_url,
        timeout_seconds=config.request_timeout_seconds,
    )
    last_applied_limit: int | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = load_policy_state(
                state_file=config.state_file,
                fallback_mbit=config.fallback_mbit,
                transmission_headroom_fraction=(config.transmission_headroom_fraction),
                max_state_age_seconds=config.max_state_age_seconds,
            )
            target_limit = state.transmission_upload_limit_kbps
            session_arguments = client.call("session_get")
            current_limit = transmission_get_current_upload_limit_kbps(session_arguments)
            current_enabled = transmission_get_current_upload_limit_enabled(session_arguments)
            if current_limit != target_limit or current_enabled is not True:
                client.call(
                    "session_set",
                    {
                        "speed_limit_up": target_limit,
                        "speed_limit_up_enabled": True,
                    },
                )
                LOG.info(
                    "updated Transmission upload limit to %s kB/s (reason=%s)",
                    target_limit,
                    state.reason,
                )
                last_applied_limit = target_limit
            elif last_applied_limit != target_limit:
                LOG.info(
                    "Transmission upload limit already at %s kB/s",
                    target_limit,
                )
                last_applied_limit = target_limit
        except TransmissionRpcError as error:
            LOG.warning(
                "skipping Transmission apply iteration after RPC failure: %s",
                error,
            )
        except Exception:
            LOG.exception("skipping Transmission apply iteration after unexpected failure")

        sleep_for = max(
            0.0,
            config.interval_seconds - (time.monotonic() - started_at),
        )
        time.sleep(sleep_for)


def run_tc_applier(
    config: TrafficControlRuntimeConfig,
    traffic_control: TrafficControl,
) -> int:
    last_applied: float | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = load_policy_state(
                state_file=config.state_file,
                fallback_mbit=config.fallback_mbit,
                transmission_headroom_fraction=(config.transmission_headroom_fraction),
                max_state_age_seconds=config.max_state_age_seconds,
            )
            if state.target_mbit != last_applied:
                traffic_control.apply_rate(state.target_mbit)
                LOG.info(
                    "updated WireGuard upload shaping to %s (reason=%s)",
                    state.target_tc_rate,
                    state.reason,
                )
                last_applied = state.target_mbit
        except ControllerError as error:
            LOG.warning("skipping tc apply iteration: %s", error)
        except Exception:
            LOG.exception("skipping tc apply iteration after unexpected failure")

        sleep_for = max(
            0.0,
            config.interval_seconds - (time.monotonic() - started_at),
        )
        time.sleep(sleep_for)
