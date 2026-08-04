from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import logging
from pathlib import Path
import subprocess
import time

from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
)

from .errors import ControllerError
from .files import write_text_atomic
from .metrics import render_metrics_text
from .policy import (
    DecisionConfig,
    decide_effective_policy,
    load_policy_state,
    save_policy_state,
)


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
    route_probe_address: str


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


def determine_default_egress_interface(route_probe_address: str) -> str:
    result = subprocess.run(
        ["ip", "-o", "route", "get", route_probe_address],
        check=True,
        text=True,
        capture_output=True,
    )
    tokens = result.stdout.split()
    for index, token in enumerate(tokens[:-1]):
        if token == "dev":
            return tokens[index + 1]
    raise ControllerError("failed to determine default egress interface")


def run_command(
    command: list[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        capture_output=True,
    )


def apply_tc_shape(iface: str, tc_rate: str) -> None:
    commands = [
        [
            "tc",
            "class",
            "change",
            "dev",
            iface,
            "parent",
            "1:1",
            "classid",
            "1:10",
            "htb",
            "rate",
            tc_rate,
            "ceil",
            tc_rate,
        ],
        [
            "tc",
            "qdisc",
            "change",
            "dev",
            iface,
            "parent",
            "1:10",
            "handle",
            "10:",
            "cake",
            "bandwidth",
            tc_rate,
            "besteffort",
            "wash",
        ],
    ]

    for command in commands:
        run_command(command)


def run_tc_applier(config: TrafficControlRuntimeConfig) -> int:
    last_applied: tuple[str, str] | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = load_policy_state(
                state_file=config.state_file,
                fallback_mbit=config.fallback_mbit,
                transmission_headroom_fraction=(config.transmission_headroom_fraction),
                max_state_age_seconds=config.max_state_age_seconds,
            )
            iface = determine_default_egress_interface(config.route_probe_address)
            desired = (iface, state.target_tc_rate)
            if desired != last_applied:
                apply_tc_shape(iface=iface, tc_rate=state.target_tc_rate)
                LOG.info(
                    "updated tc WireGuard upload shaping on %s to %s (reason=%s)",
                    iface,
                    state.target_tc_rate,
                    state.reason,
                )
                last_applied = desired
        except ControllerError as error:
            LOG.warning("skipping tc apply iteration: %s", error)
        except subprocess.CalledProcessError as error:
            LOG.warning(
                "skipping tc apply iteration after command failure: %s",
                error.stderr.strip() if error.stderr else error,
            )
        except Exception:
            LOG.exception("skipping tc apply iteration after unexpected failure")

        sleep_for = max(
            0.0,
            config.interval_seconds - (time.monotonic() - started_at),
        )
        time.sleep(sleep_for)
