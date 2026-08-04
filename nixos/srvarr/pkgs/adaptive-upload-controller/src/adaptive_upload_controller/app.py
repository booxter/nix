from __future__ import annotations

import argparse
import logging
from pathlib import Path
from typing import NoReturn

from .jellyfin import DEFAULT_MEDIA_TYPES
from .policy import DecisionConfig
from .runtime import (
    DeciderRuntimeConfig,
    TrafficControlRuntimeConfig,
    TransmissionRuntimeConfig,
    run_decider,
    run_tc_applier,
    run_transmission_applier,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Coordinate adaptive torrent upload limits from Jellyfin activity."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    decider = subparsers.add_parser(
        "decide",
        help="Poll Jellyfin exporter and write the desired upload policy.",
    )
    decider.add_argument(
        "--exporter-url",
        required=True,
        help="Jellyfin exporter metrics URL.",
    )
    decider.add_argument(
        "--state-file",
        required=True,
        help="Path to the shared state JSON file.",
    )
    decider.add_argument("--interval-seconds", type=float, default=30.0)
    decider.add_argument("--request-timeout-seconds", type=float, default=10.0)
    decider.add_argument(
        "--ca-file",
        default="",
        help="Optional CA bundle path used when polling an HTTPS exporter.",
    )
    decider.add_argument(
        "--client-cert-file",
        default="",
        help="Optional client certificate path used for HTTPS exporter mTLS.",
    )
    decider.add_argument(
        "--client-key-file",
        default="",
        help="Optional client key path used for HTTPS exporter mTLS.",
    )
    decider.add_argument("--no-streams-mbit", type=float, default=25.0)
    decider.add_argument("--minimum-streams-mbit", type=float, default=2.0)
    decider.add_argument("--fallback-mbit", type=float, default=8.0)
    decider.add_argument(
        "--stream-bitrate-headroom-fraction",
        type=float,
        default=0.2,
    )
    decider.add_argument("--relaxation-hold-seconds", type=float, default=300.0)
    decider.add_argument(
        "--transmission-headroom-fraction",
        type=float,
        default=0.95,
    )
    decider.add_argument(
        "--metrics-file",
        default="",
        help="Optional Prometheus textfile path for policy metrics.",
    )
    decider.add_argument(
        "--media-types",
        nargs="+",
        default=sorted(DEFAULT_MEDIA_TYPES),
        help="Jellyfin media types included in uplink budgeting.",
    )

    transmission = subparsers.add_parser(
        "apply-transmission",
        help="Apply the current policy to Transmission's upload limit.",
    )
    transmission.add_argument("--rpc-url", required=True, help="Transmission RPC URL.")
    transmission.add_argument(
        "--state-file",
        required=True,
        help="Path to the shared state JSON file.",
    )
    transmission.add_argument("--interval-seconds", type=float, default=30.0)
    transmission.add_argument("--request-timeout-seconds", type=float, default=15.0)
    transmission.add_argument("--fallback-mbit", type=float, default=8.0)
    transmission.add_argument(
        "--transmission-headroom-fraction",
        type=float,
        default=0.95,
    )
    transmission.add_argument("--max-state-age-seconds", type=float, default=90.0)

    tc_applier = subparsers.add_parser(
        "apply-tc",
        help="Apply the current policy to the WireGuard tc shaper.",
    )
    tc_applier.add_argument(
        "--state-file",
        required=True,
        help="Path to the shared state JSON file.",
    )
    tc_applier.add_argument("--interval-seconds", type=float, default=30.0)
    tc_applier.add_argument("--fallback-mbit", type=float, default=8.0)
    tc_applier.add_argument(
        "--transmission-headroom-fraction",
        type=float,
        default=0.95,
    )
    tc_applier.add_argument("--max-state-age-seconds", type=float, default=90.0)
    tc_applier.add_argument(
        "--outer-link-rate",
        required=True,
        help="Parent HTB class rate for non-WireGuard traffic.",
    )
    tc_applier.add_argument(
        "--endpoint-port",
        type=int,
        required=True,
        help="WireGuard UDP endpoint port.",
    )
    tc_applier.add_argument("--route-probe-address", default="1.1.1.1")

    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity.",
    )
    return parser.parse_args()


def _decision_config(args: argparse.Namespace) -> DecisionConfig:
    return DecisionConfig(
        exporter_url=str(args.exporter_url),
        request_timeout_seconds=float(args.request_timeout_seconds),
        ca_file=str(args.ca_file),
        client_cert_file=str(args.client_cert_file),
        client_key_file=str(args.client_key_file),
        media_types=frozenset(str(value) for value in args.media_types),
        no_streams_mbit=float(args.no_streams_mbit),
        minimum_streams_mbit=float(args.minimum_streams_mbit),
        fallback_mbit=float(args.fallback_mbit),
        stream_bitrate_headroom_fraction=float(args.stream_bitrate_headroom_fraction),
        relaxation_hold_seconds=float(args.relaxation_hold_seconds),
        transmission_headroom_fraction=float(args.transmission_headroom_fraction),
    )


def _decider_runtime_config(args: argparse.Namespace) -> DeciderRuntimeConfig:
    metrics_file = str(args.metrics_file).strip()
    return DeciderRuntimeConfig(
        decision=_decision_config(args),
        state_file=Path(str(args.state_file)),
        metrics_file=Path(metrics_file) if metrics_file else None,
        interval_seconds=float(args.interval_seconds),
    )


def _transmission_runtime_config(
    args: argparse.Namespace,
) -> TransmissionRuntimeConfig:
    return TransmissionRuntimeConfig(
        rpc_url=str(args.rpc_url),
        state_file=Path(str(args.state_file)),
        interval_seconds=float(args.interval_seconds),
        request_timeout_seconds=float(args.request_timeout_seconds),
        fallback_mbit=float(args.fallback_mbit),
        transmission_headroom_fraction=float(args.transmission_headroom_fraction),
        max_state_age_seconds=float(args.max_state_age_seconds),
    )


def _traffic_control_runtime_config(
    args: argparse.Namespace,
) -> TrafficControlRuntimeConfig:
    return TrafficControlRuntimeConfig(
        state_file=Path(str(args.state_file)),
        interval_seconds=float(args.interval_seconds),
        fallback_mbit=float(args.fallback_mbit),
        transmission_headroom_fraction=float(args.transmission_headroom_fraction),
        max_state_age_seconds=float(args.max_state_age_seconds),
        route_probe_address=str(args.route_probe_address),
    )


def _unknown_command(command: object) -> NoReturn:
    raise SystemExit(f"unknown command {command!r}")


def main() -> int:
    args = parse_args()
    if args.command == "decide" and bool(args.client_cert_file) != bool(args.client_key_file):
        raise SystemExit("--client-cert-file and --client-key-file must be provided together")
    logging.basicConfig(
        level=getattr(logging, str(args.log_level)),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.command == "decide":
        return run_decider(_decider_runtime_config(args))
    if args.command == "apply-transmission":
        return run_transmission_applier(_transmission_runtime_config(args))
    if args.command == "apply-tc":
        return run_tc_applier(_traffic_control_runtime_config(args))
    return _unknown_command(args.command)
