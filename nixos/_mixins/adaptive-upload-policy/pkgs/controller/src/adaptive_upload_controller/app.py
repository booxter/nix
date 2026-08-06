from __future__ import annotations

import argparse
import logging
from pathlib import Path
from typing import NoReturn

from .config import ControllerConfig, load_config
from .errors import ControllerError
from .policy import DecisionConfig
from .runtime import (
    DeciderRuntimeConfig,
    QosRuntimeConfig,
    TransmissionRuntimeConfig,
    run_decider,
    run_qos_applier,
    run_transmission_applier,
)
from .traffic_control import QosctlTrafficControl, SubprocessRunner


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Coordinate a Jellyfin-aware adaptive upload policy."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command, help_text in (
        ("decide", "Poll Jellyfin and write the desired upload policy."),
        ("apply-transmission", "Apply the current policy to Transmission."),
        ("apply-qos", "Apply the current policy to a configured QoS limit."),
    ):
        subparser = subparsers.add_parser(command, help=help_text)
        subparser.add_argument("--config", required=True, type=Path)
        subparser.add_argument(
            "--log-level",
            default="INFO",
            choices=["DEBUG", "INFO", "WARNING", "ERROR"],
            help="Logging verbosity.",
        )
    return parser.parse_args()


def decision_config(config: ControllerConfig) -> DecisionConfig:
    source = config.jellyfin
    return DecisionConfig(
        exporter_url=source.exporter_url,
        request_timeout_seconds=source.request_timeout_seconds,
        ca_file=source.ca_file,
        client_cert_file=source.client_cert_file,
        client_key_file=source.client_key_file,
        media_types=source.media_types,
        no_streams_mbit=source.idle_rate_mbit,
        minimum_streams_mbit=source.minimum_rate_mbit,
        fallback_mbit=config.fallback_rate_mbit,
        stream_bitrate_headroom_fraction=source.bitrate_headroom_fraction,
        relaxation_hold_seconds=source.relaxation_hold_seconds,
    )


def decider_runtime_config(config: ControllerConfig) -> DeciderRuntimeConfig:
    return DeciderRuntimeConfig(
        decision=decision_config(config),
        state_file=config.state_file,
        metrics_file=config.metrics_file,
        interval_seconds=config.interval_seconds,
    )


def transmission_runtime_config(config: ControllerConfig) -> TransmissionRuntimeConfig:
    output = config.transmission
    if output is None:
        raise ControllerError("Transmission output is not configured")
    return TransmissionRuntimeConfig(
        rpc_url=output.rpc_url,
        state_file=config.state_file,
        interval_seconds=config.interval_seconds,
        request_timeout_seconds=output.request_timeout_seconds,
        fallback_mbit=config.fallback_rate_mbit,
        transmission_headroom_fraction=output.headroom_fraction,
        max_state_age_seconds=config.max_state_age_seconds,
    )


def qos_runtime_config(config: ControllerConfig) -> QosRuntimeConfig:
    if config.qos is None:
        raise ControllerError("QoS output is not configured")
    return QosRuntimeConfig(
        state_file=config.state_file,
        interval_seconds=config.interval_seconds,
        fallback_mbit=config.fallback_rate_mbit,
        max_state_age_seconds=config.max_state_age_seconds,
    )


def _unknown_command(command: object) -> NoReturn:
    raise SystemExit(f"unknown command {command!r}")


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, str(args.log_level)),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        config = load_config(args.config)
        if args.command == "decide":
            return run_decider(decider_runtime_config(config))
        if args.command == "apply-transmission":
            return run_transmission_applier(transmission_runtime_config(config))
        if args.command == "apply-qos":
            output = config.qos
            if output is None:
                raise ControllerError("QoS output is not configured")
            traffic_control = QosctlTrafficControl(
                executable=output.executable,
                config_file=output.config_file,
                limit=output.limit,
                runner=SubprocessRunner(),
            )
            return run_qos_applier(qos_runtime_config(config), traffic_control)
    except ControllerError as error:
        raise SystemExit(str(error)) from error
    return _unknown_command(args.command)
