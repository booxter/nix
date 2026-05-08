#!/usr/bin/env python3

import argparse
import datetime
import ipaddress
import json
import logging
import math
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


LOG = logging.getLogger("adaptive-upload-controller")
DEFAULT_MEDIA_TYPES = {
    "audio",
    "audiobook",
    "episode",
    "movie",
    "musicvideo",
    "trailer",
    "video",
}
PLAYING_METRIC_RE = re.compile(
    r"^jellyfin_now_playing_state\{(?P<labels>.*)\}\s+"
    r"(?P<value>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)"
    r"(?:\s+\d+)?$"
)
LABEL_PAIR_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"')
TARGET_MBIT_EPSILON = 0.05


class ControllerError(RuntimeError):
    pass


class TransmissionRpcError(RuntimeError):
    pass


class TransmissionRpcClient:
    def __init__(self, rpc_url: str, timeout_seconds: float) -> None:
        self.rpc_url = rpc_url
        self.timeout_seconds = timeout_seconds
        self.session_id: str | None = None

    def call(self, method: str, arguments: dict | None = None) -> dict:
        payload = json.dumps(
            {
                "method": method,
                "arguments": arguments or {},
            }
        ).encode("utf-8")

        for attempt in range(2):
            headers = {
                "Content-Type": "application/json",
            }
            if self.session_id is not None:
                headers["X-Transmission-Session-Id"] = self.session_id

            request = urllib.request.Request(
                self.rpc_url,
                data=payload,
                headers=headers,
                method="POST",
            )

            try:
                with urllib.request.urlopen(
                    request, timeout=self.timeout_seconds
                ) as response:
                    body = response.read().decode("utf-8")
            except urllib.error.HTTPError as exc:
                if exc.code == 409 and attempt == 0:
                    session_id = exc.headers.get("X-Transmission-Session-Id")
                    if session_id:
                        self.session_id = session_id
                        continue
                raise TransmissionRpcError(
                    f"HTTP {exc.code} from Transmission RPC"
                ) from exc
            except (TimeoutError, socket.timeout, urllib.error.URLError) as exc:
                raise TransmissionRpcError(
                    f"request to Transmission RPC failed: {exc}"
                ) from exc

            try:
                parsed = json.loads(body)
            except json.JSONDecodeError as exc:
                raise TransmissionRpcError(
                    "Transmission RPC returned invalid JSON"
                ) from exc

            result = parsed.get("result")
            if result != "success":
                raise TransmissionRpcError(f"Transmission RPC returned {result!r}")

            arguments_out = parsed.get("arguments", {})
            if not isinstance(arguments_out, dict):
                raise TransmissionRpcError(
                    "Transmission RPC returned invalid arguments payload"
                )
            return arguments_out

        raise TransmissionRpcError("failed to negotiate Transmission session id")


def now_utc_iso8601() -> str:
    return datetime_to_utc_iso8601(datetime.datetime.now(datetime.timezone.utc))


def datetime_to_utc_iso8601(value: datetime.datetime) -> str:
    return (
        value.astimezone(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def parse_utc_iso8601(value: str) -> datetime.datetime | None:
    normalized = value.strip()
    if not normalized:
        return None
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.astimezone(datetime.timezone.utc)


def write_json_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        dir=str(path.parent), prefix=f".{path.name}.", text=True
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def round_target_mbit(target_mbit: float) -> float:
    return round(target_mbit, 1)


def format_target_mbit(target_mbit: float) -> str:
    return f"{round_target_mbit(target_mbit):.1f}".rstrip("0").rstrip(".")


def calculate_transmission_upload_limit_kbps(
    target_mbit: float, headroom_fraction: float
) -> int:
    return max(1, int((target_mbit * 1000.0 / 8.0) * headroom_fraction))


def calculate_public_group_limit_kbps(
    transmission_upload_limit_kbps: int, public_group_fraction: float
) -> int:
    return max(1, int(transmission_upload_limit_kbps * public_group_fraction))


def default_policy_state(
    fallback_mbit: float,
    transmission_headroom_fraction: float,
    public_group_fraction: float,
    reason: str,
    exporter_ok: bool,
    active_external_media_streams: int | None,
) -> dict:
    transmission_upload_limit_kbps = calculate_transmission_upload_limit_kbps(
        fallback_mbit, transmission_headroom_fraction
    )
    return {
        "active_external_media_streams": active_external_media_streams,
        "active_external_media_bitrate_bits_per_second": None,
        "active_media_streams_total": active_external_media_streams,
        "exporter_ok": exporter_ok,
        "missing_external_media_bitrate_sessions": None,
        "public_group_upload_limit_kbps": calculate_public_group_limit_kbps(
            transmission_upload_limit_kbps, public_group_fraction
        ),
        "reason": reason,
        "reserved_external_media_bandwidth_mbit": None,
        "target_mbit": float(fallback_mbit),
        "target_tc_rate": f"{format_target_mbit(fallback_mbit)}mbit",
        "transmission_upload_limit_kbps": transmission_upload_limit_kbps,
        "updated_at": now_utc_iso8601(),
    }


def decode_prometheus_label_value(value: str) -> str:
    return (
        value.replace(r"\\", "\\")
        .replace(r"\"", '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
    )


def parse_prometheus_labels(label_text: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    for match in LABEL_PAIR_RE.finditer(label_text):
        labels[match.group(1)] = decode_prometheus_label_value(match.group(2))
    return labels


def normalize_remote_ip(endpoint: str) -> ipaddress._BaseAddress | None:
    value = endpoint.strip()
    if not value:
        return None

    if value.startswith("[") and "]" in value:
        value = value[1 : value.index("]")]
    elif value.count(":") == 1 and "." in value:
        value = value.rsplit(":", 1)[0]

    try:
        return ipaddress.ip_address(value)
    except ValueError:
        return None


def is_internal_remote_endpoint(endpoint: str) -> bool:
    remote_ip = normalize_remote_ip(endpoint)
    if remote_ip is None:
        return False
    return (
        remote_ip.is_private
        or remote_ip.is_loopback
        or remote_ip.is_link_local
        or remote_ip.is_reserved
    )


def fetch_url_text(url: str, timeout_seconds: float) -> str:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return response.read().decode("utf-8")
    except (TimeoutError, socket.timeout, urllib.error.URLError) as exc:
        raise ControllerError(f"request to {url} failed: {exc}") from exc


def collect_media_stream_stats(
    metrics_text: str, media_types: set[str]
) -> tuple[int, int, int, int]:
    external_session_keys: set[tuple[str, str, str]] = set()
    playing_media_session_keys: set[tuple[str, str, str]] = set()
    bitrate_by_session_key: dict[tuple[str, str, str], int] = {}

    for raw_line in metrics_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("jellyfin_user_active{"):
            match = PLAYING_METRIC_RE.match(
                line.replace("jellyfin_user_active{", "jellyfin_now_playing_state{", 1)
            )
            if match is None:
                continue
            labels = parse_prometheus_labels(match.group("labels"))
            session_key = (
                labels.get("user_id", ""),
                labels.get("username", ""),
                labels.get("device", ""),
            )
            if (
                session_key[0]
                and session_key[1]
                and session_key[2]
                and not is_internal_remote_endpoint(labels.get("ip_address", ""))
            ):
                external_session_keys.add(session_key)
            continue

        if line.startswith("jellyfin_now_playing_bitrate_bits_per_second{"):
            match = PLAYING_METRIC_RE.match(
                line.replace(
                    "jellyfin_now_playing_bitrate_bits_per_second{",
                    "jellyfin_now_playing_state{",
                    1,
                )
            )
            if match is None:
                continue
            try:
                value = float(match.group("value"))
            except ValueError:
                continue
            if value <= 0:
                continue
            labels = parse_prometheus_labels(match.group("labels"))
            media_type = labels.get("type", "").lower()
            if media_type not in media_types:
                continue
            session_key = (
                labels.get("user_id", ""),
                labels.get("username", ""),
                labels.get("device", ""),
            )
            if session_key[0] and session_key[1] and session_key[2]:
                bitrate_by_session_key[session_key] = int(value)
            continue

        if not line.startswith("jellyfin_now_playing_state{"):
            continue

        match = PLAYING_METRIC_RE.match(line)
        if match is None:
            continue
        try:
            value = float(match.group("value"))
        except ValueError:
            continue
        if value <= 0.5:
            continue

        labels = parse_prometheus_labels(match.group("labels"))
        media_type = labels.get("type", "").lower()
        if media_type in media_types:
            session_key = (
                labels.get("user_id", ""),
                labels.get("username", ""),
                labels.get("device", ""),
            )
            if session_key[0] and session_key[1] and session_key[2]:
                playing_media_session_keys.add(session_key)

    total_streams = len(playing_media_session_keys)
    active_external_media_session_keys = {
        session_key
        for session_key in playing_media_session_keys
        if session_key in external_session_keys
    }
    external_streams = len(active_external_media_session_keys)

    total_external_media_bitrate_bps = 0
    missing_external_media_bitrate_sessions = 0
    for session_key in active_external_media_session_keys:
        bitrate_bps = bitrate_by_session_key.get(session_key)
        if bitrate_bps is None or bitrate_bps <= 0:
            missing_external_media_bitrate_sessions += 1
            continue
        total_external_media_bitrate_bps += bitrate_bps

    return (
        total_streams,
        external_streams,
        total_external_media_bitrate_bps,
        missing_external_media_bitrate_sessions,
    )


def observed_policy_state_from_stream_stats(
    args: argparse.Namespace,
    total_media_streams: int,
    active_external_media_streams: int,
    active_external_media_bitrate_bits_per_second: int,
    missing_external_media_bitrate_sessions: int,
) -> dict:
    if active_external_media_streams == 0:
        target_mbit = float(args.no_streams_mbit)
        reason = "no_active_media_streams"
        reserved_external_media_bandwidth_mbit = 0.0
    elif missing_external_media_bitrate_sessions > 0:
        target_mbit = float(args.minimum_streams_mbit)
        reason = "active_media_streams_missing_bitrate"
        reserved_external_media_bandwidth_mbit = None
    else:
        reserved_external_media_bandwidth_mbit = round_target_mbit(
            (active_external_media_bitrate_bits_per_second / 1_000_000.0)
            * (1.0 + args.stream_bitrate_headroom_fraction)
        )
        target_mbit = round_target_mbit(
            min(
                float(args.no_streams_mbit),
                max(
                    float(args.minimum_streams_mbit),
                    float(args.no_streams_mbit)
                    - reserved_external_media_bandwidth_mbit,
                ),
            )
        )
        reason = "bitrate_based_active_media_streams"

    return {
        "active_external_media_bitrate_bits_per_second": (
            active_external_media_bitrate_bits_per_second
        ),
        "active_external_media_streams": active_external_media_streams,
        "active_media_streams_total": total_media_streams,
        "exporter_ok": True,
        "missing_external_media_bitrate_sessions": (
            missing_external_media_bitrate_sessions
        ),
        "reason": reason,
        "reserved_external_media_bandwidth_mbit": (
            reserved_external_media_bandwidth_mbit
        ),
        "target_mbit": target_mbit,
    }


def fallback_observed_policy_state(args: argparse.Namespace, reason: str) -> dict:
    return {
        "active_external_media_bitrate_bits_per_second": None,
        "active_external_media_streams": None,
        "active_media_streams_total": None,
        "exporter_ok": False,
        "missing_external_media_bitrate_sessions": None,
        "reason": reason,
        "reserved_external_media_bandwidth_mbit": None,
        "target_mbit": float(args.fallback_mbit),
    }


def load_decider_state(
    state_file: Path, args: argparse.Namespace
) -> tuple[float | None, float | None, datetime.datetime | None]:
    try:
        parsed = json.loads(state_file.read_text())
    except (OSError, json.JSONDecodeError):
        return None, None, None

    if not isinstance(parsed, dict):
        return None, None, None

    effective_target_mbit = parsed.get("target_mbit")
    if (
        not isinstance(effective_target_mbit, (int, float))
        or isinstance(effective_target_mbit, bool)
        or not math.isfinite(float(effective_target_mbit))
    ):
        effective_target_mbit = None
    else:
        effective_target_mbit = round_target_mbit(float(effective_target_mbit))
        if (
            effective_target_mbit
            < float(args.minimum_streams_mbit) - TARGET_MBIT_EPSILON
            or effective_target_mbit > float(args.no_streams_mbit) + TARGET_MBIT_EPSILON
        ):
            effective_target_mbit = None

    pending_target_mbit = parsed.get("relaxation_pending_target_mbit")
    pending_since = parsed.get("relaxation_pending_since")
    if (
        not isinstance(pending_target_mbit, (int, float))
        or isinstance(pending_target_mbit, bool)
        or not math.isfinite(float(pending_target_mbit))
        or not isinstance(pending_since, str)
    ):
        return effective_target_mbit, None, None

    pending_target_mbit = round_target_mbit(float(pending_target_mbit))
    if (
        pending_target_mbit < float(args.minimum_streams_mbit) - TARGET_MBIT_EPSILON
        or pending_target_mbit > float(args.no_streams_mbit) + TARGET_MBIT_EPSILON
    ):
        return effective_target_mbit, None, None

    parsed_pending_since = parse_utc_iso8601(pending_since)
    if parsed_pending_since is None:
        return effective_target_mbit, None, None

    return effective_target_mbit, pending_target_mbit, parsed_pending_since


def build_policy_state(
    *,
    args: argparse.Namespace,
    observed_state: dict,
    effective_target_mbit: float,
    effective_reason: str,
    relaxation_pending_target_mbit: float | None,
    relaxation_pending_since: datetime.datetime | None,
) -> dict:
    effective_target_mbit = round_target_mbit(effective_target_mbit)
    transmission_upload_limit_kbps = calculate_transmission_upload_limit_kbps(
        effective_target_mbit, args.transmission_headroom_fraction
    )
    return {
        "active_external_media_bitrate_bits_per_second": observed_state[
            "active_external_media_bitrate_bits_per_second"
        ],
        "active_external_media_streams": observed_state[
            "active_external_media_streams"
        ],
        "active_media_streams_total": observed_state["active_media_streams_total"],
        "exporter_ok": observed_state["exporter_ok"],
        "missing_external_media_bitrate_sessions": observed_state[
            "missing_external_media_bitrate_sessions"
        ],
        "observed_reason": observed_state["reason"],
        "observed_target_mbit": observed_state["target_mbit"],
        "public_group_upload_limit_kbps": calculate_public_group_limit_kbps(
            transmission_upload_limit_kbps, args.public_group_fraction
        ),
        "reason": effective_reason,
        "relaxation_hold_seconds": args.relaxation_hold_seconds,
        "relaxation_pending_since": (
            datetime_to_utc_iso8601(relaxation_pending_since)
            if relaxation_pending_since is not None
            else None
        ),
        "relaxation_pending_target_mbit": (
            round_target_mbit(relaxation_pending_target_mbit)
            if relaxation_pending_target_mbit is not None
            else None
        ),
        "reserved_external_media_bandwidth_mbit": observed_state[
            "reserved_external_media_bandwidth_mbit"
        ],
        "target_mbit": effective_target_mbit,
        "target_tc_rate": f"{format_target_mbit(effective_target_mbit)}mbit",
        "transmission_upload_limit_kbps": transmission_upload_limit_kbps,
        "updated_at": now_utc_iso8601(),
    }


def decide_observed_policy_state(args: argparse.Namespace) -> dict:
    try:
        metrics_text = fetch_url_text(args.exporter_url, args.request_timeout_seconds)
        (
            total_media_streams,
            active_external_media_streams,
            active_external_media_bitrate_bits_per_second,
            missing_external_media_bitrate_sessions,
        ) = collect_media_stream_stats(metrics_text, set(args.media_types))
        return observed_policy_state_from_stream_stats(
            args=args,
            total_media_streams=total_media_streams,
            active_external_media_streams=active_external_media_streams,
            active_external_media_bitrate_bits_per_second=(
                active_external_media_bitrate_bits_per_second
            ),
            missing_external_media_bitrate_sessions=(
                missing_external_media_bitrate_sessions
            ),
        )
    except ControllerError as exc:
        LOG.warning("using conservative fallback after exporter failure: %s", exc)
        return fallback_observed_policy_state(args, "exporter_unreachable")


def decide_effective_policy_state(args: argparse.Namespace, state_file: Path) -> dict:
    observed_state = decide_observed_policy_state(args)
    now = datetime.datetime.now(datetime.timezone.utc)
    (
        current_effective_target_mbit,
        relaxation_pending_target_mbit,
        relaxation_pending_since,
    ) = load_decider_state(state_file, args)

    observed_target_mbit = observed_state["target_mbit"]

    if current_effective_target_mbit is None:
        return build_policy_state(
            args=args,
            observed_state=observed_state,
            effective_target_mbit=observed_target_mbit,
            effective_reason=observed_state["reason"],
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )

    if observed_target_mbit < current_effective_target_mbit - TARGET_MBIT_EPSILON:
        return build_policy_state(
            args=args,
            observed_state=observed_state,
            effective_target_mbit=observed_target_mbit,
            effective_reason=observed_state["reason"],
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )

    if abs(observed_target_mbit - current_effective_target_mbit) <= TARGET_MBIT_EPSILON:
        return build_policy_state(
            args=args,
            observed_state=observed_state,
            effective_target_mbit=current_effective_target_mbit,
            effective_reason=observed_state["reason"],
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )

    if (
        relaxation_pending_target_mbit is None
        or abs(relaxation_pending_target_mbit - observed_target_mbit)
        > TARGET_MBIT_EPSILON
        or relaxation_pending_since is None
    ):
        return build_policy_state(
            args=args,
            observed_state=observed_state,
            effective_target_mbit=current_effective_target_mbit,
            effective_reason=(
                f"holding_before_relaxation_to_{observed_state['reason']}"
            ),
            relaxation_pending_target_mbit=observed_target_mbit,
            relaxation_pending_since=now,
        )

    if (now - relaxation_pending_since).total_seconds() >= args.relaxation_hold_seconds:
        return build_policy_state(
            args=args,
            observed_state=observed_state,
            effective_target_mbit=observed_target_mbit,
            effective_reason=observed_state["reason"],
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )

    return build_policy_state(
        args=args,
        observed_state=observed_state,
        effective_target_mbit=current_effective_target_mbit,
        effective_reason=f"holding_before_relaxation_to_{observed_state['reason']}",
        relaxation_pending_target_mbit=relaxation_pending_target_mbit,
        relaxation_pending_since=relaxation_pending_since,
    )


def load_policy_state(
    state_file: Path,
    fallback_mbit: float,
    transmission_headroom_fraction: float,
    public_group_fraction: float,
    max_state_age_seconds: float | None,
) -> dict:
    fallback_state = default_policy_state(
        fallback_mbit=fallback_mbit,
        transmission_headroom_fraction=transmission_headroom_fraction,
        public_group_fraction=public_group_fraction,
        reason="missing_or_invalid_state_file",
        exporter_ok=False,
        active_external_media_streams=None,
    )

    try:
        raw_text = state_file.read_text()
    except OSError as exc:
        LOG.warning("unable to read state file %s: %s", state_file, exc)
        return fallback_state

    try:
        parsed = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        LOG.warning("state file %s contains invalid JSON: %s", state_file, exc)
        return fallback_state

    if not isinstance(parsed, dict):
        LOG.warning("state file %s does not contain a JSON object", state_file)
        return fallback_state

    target_mbit = parsed.get("target_mbit")
    transmission_upload_limit_kbps = parsed.get("transmission_upload_limit_kbps")
    public_group_upload_limit_kbps = parsed.get("public_group_upload_limit_kbps")
    if (
        not isinstance(target_mbit, (int, float))
        or isinstance(target_mbit, bool)
        or float(target_mbit) <= 0
        or not isinstance(transmission_upload_limit_kbps, int)
        or transmission_upload_limit_kbps <= 0
        or not isinstance(public_group_upload_limit_kbps, int)
        or public_group_upload_limit_kbps <= 0
    ):
        LOG.warning(
            "state file %s is missing expected numeric policy fields", state_file
        )
        return fallback_state

    if max_state_age_seconds is not None:
        updated_at = parsed.get("updated_at")
        parsed_updated_at = (
            parse_utc_iso8601(updated_at) if isinstance(updated_at, str) else None
        )
        if parsed_updated_at is None:
            LOG.warning(
                "state file %s is missing a valid updated_at timestamp", state_file
            )
            fallback_state["reason"] = "stale_or_invalid_state_file"
            return fallback_state

        age_seconds = (
            datetime.datetime.now(datetime.timezone.utc) - parsed_updated_at
        ).total_seconds()
        if age_seconds > max_state_age_seconds:
            LOG.warning(
                "state file %s is stale (age %.1fs exceeds %.1fs)",
                state_file,
                age_seconds,
                max_state_age_seconds,
            )
            fallback_state["reason"] = "stale_state_file"
            return fallback_state

    return parsed


def transmission_get_current_upload_limit_kbps(session_arguments: dict) -> int | None:
    for key in ("speed-limit-up", "speed_limit_up"):
        value = session_arguments.get(key)
        if isinstance(value, int):
            return value
    return None


def transmission_get_current_upload_limit_enabled(
    session_arguments: dict,
) -> bool | None:
    for key in ("speed-limit-up-enabled", "speed_limit_up_enabled"):
        value = session_arguments.get(key)
        if isinstance(value, bool):
            return value
    return None


def run_decider(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file)
    last_signature: tuple | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = decide_effective_policy_state(args, state_file)
            signature = (
                state["target_mbit"],
                state["observed_target_mbit"],
                state["transmission_upload_limit_kbps"],
                state["public_group_upload_limit_kbps"],
                state["active_external_media_streams"],
                state["active_external_media_bitrate_bits_per_second"],
                state["active_media_streams_total"],
                state["missing_external_media_bitrate_sessions"],
                state["reason"],
                state["observed_reason"],
                state["exporter_ok"],
                state["relaxation_pending_target_mbit"],
                state["relaxation_pending_since"],
                state["reserved_external_media_bandwidth_mbit"],
            )
            write_json_atomic(state_file, state)
            if signature != last_signature:
                LOG.info(
                    "policy updated: observed_target_mbit=%s target_mbit=%s transmission_upload_limit_kbps=%s public_group_upload_limit_kbps=%s active_external_media_streams=%s active_external_media_bitrate_bits_per_second=%s active_media_streams_total=%s missing_external_media_bitrate_sessions=%s reserved_external_media_bandwidth_mbit=%s reason=%s observed_reason=%s exporter_ok=%s relaxation_pending_target_mbit=%s relaxation_pending_since=%s",
                    state["observed_target_mbit"],
                    state["target_mbit"],
                    state["transmission_upload_limit_kbps"],
                    state["public_group_upload_limit_kbps"],
                    state["active_external_media_streams"],
                    state["active_external_media_bitrate_bits_per_second"],
                    state["active_media_streams_total"],
                    state["missing_external_media_bitrate_sessions"],
                    state["reserved_external_media_bandwidth_mbit"],
                    state["reason"],
                    state["observed_reason"],
                    state["exporter_ok"],
                    state["relaxation_pending_target_mbit"],
                    state["relaxation_pending_since"],
                )
                last_signature = signature
        except Exception:
            LOG.exception("failed to refresh adaptive upload policy state")

        sleep_for = max(0.0, args.interval_seconds - (time.monotonic() - started_at))
        time.sleep(sleep_for)


def run_transmission_applier(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file)
    client = TransmissionRpcClient(
        rpc_url=args.rpc_url,
        timeout_seconds=args.request_timeout_seconds,
    )
    last_applied_limit: int | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = load_policy_state(
                state_file=state_file,
                fallback_mbit=args.fallback_mbit,
                transmission_headroom_fraction=args.transmission_headroom_fraction,
                public_group_fraction=args.public_group_fraction,
                max_state_age_seconds=args.max_state_age_seconds,
            )
            target_limit = state["transmission_upload_limit_kbps"]
            session_arguments = client.call("session-get")
            current_limit = transmission_get_current_upload_limit_kbps(
                session_arguments
            )
            current_enabled = transmission_get_current_upload_limit_enabled(
                session_arguments
            )
            if current_limit != target_limit or current_enabled is not True:
                client.call(
                    "session-set",
                    {
                        "speed-limit-up": target_limit,
                        "speed-limit-up-enabled": True,
                    },
                )
                LOG.info(
                    "updated Transmission upload limit to %s kB/s (reason=%s)",
                    target_limit,
                    state.get("reason"),
                )
                last_applied_limit = target_limit
            elif last_applied_limit != target_limit:
                LOG.info("Transmission upload limit already at %s kB/s", target_limit)
                last_applied_limit = target_limit
        except TransmissionRpcError as exc:
            LOG.warning(
                "skipping Transmission apply iteration after RPC failure: %s", exc
            )
        except Exception:
            LOG.exception(
                "skipping Transmission apply iteration after unexpected failure"
            )

        sleep_for = max(0.0, args.interval_seconds - (time.monotonic() - started_at))
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
    command: list[str], *, check: bool = True
) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=check, text=True, capture_output=True)


def apply_tc_shape(
    iface: str,
    tc_rate: str,
) -> None:
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


def run_tc_applier(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file)
    last_applied: tuple[str, str] | None = None

    while True:
        started_at = time.monotonic()
        try:
            state = load_policy_state(
                state_file=state_file,
                fallback_mbit=args.fallback_mbit,
                transmission_headroom_fraction=args.transmission_headroom_fraction,
                public_group_fraction=args.public_group_fraction,
                max_state_age_seconds=args.max_state_age_seconds,
            )
            iface = determine_default_egress_interface(args.route_probe_address)
            tc_rate = state["target_tc_rate"]
            desired = (iface, tc_rate)
            if desired != last_applied:
                apply_tc_shape(
                    iface=iface,
                    tc_rate=tc_rate,
                )
                LOG.info(
                    "updated tc WireGuard upload shaping on %s to %s (reason=%s)",
                    iface,
                    tc_rate,
                    state.get("reason"),
                )
                last_applied = desired
        except ControllerError as exc:
            LOG.warning("skipping tc apply iteration: %s", exc)
        except subprocess.CalledProcessError as exc:
            LOG.warning(
                "skipping tc apply iteration after command failure: %s",
                exc.stderr.strip() if exc.stderr else exc,
            )
        except Exception:
            LOG.exception("skipping tc apply iteration after unexpected failure")

        sleep_for = max(0.0, args.interval_seconds - (time.monotonic() - started_at))
        time.sleep(sleep_for)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Coordinate adaptive torrent upload limits from Jellyfin playback activity."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    decider = subparsers.add_parser(
        "decide", help="Poll Jellyfin exporter and write the desired upload policy."
    )
    decider.add_argument(
        "--exporter-url", required=True, help="Jellyfin exporter metrics URL."
    )
    decider.add_argument(
        "--state-file", required=True, help="Path to the shared state JSON file."
    )
    decider.add_argument("--interval-seconds", type=float, default=30.0)
    decider.add_argument("--request-timeout-seconds", type=float, default=10.0)
    decider.add_argument("--no-streams-mbit", type=float, default=24.0)
    decider.add_argument("--minimum-streams-mbit", type=float, default=2.0)
    decider.add_argument("--fallback-mbit", type=float, default=8.0)
    decider.add_argument("--stream-bitrate-headroom-fraction", type=float, default=0.2)
    decider.add_argument("--relaxation-hold-seconds", type=float, default=300.0)
    decider.add_argument("--transmission-headroom-fraction", type=float, default=0.95)
    decider.add_argument("--public-group-fraction", type=float, default=0.4)
    decider.add_argument(
        "--media-types",
        nargs="+",
        default=sorted(DEFAULT_MEDIA_TYPES),
        help="Jellyfin media types that count toward adaptive uplink budgeting.",
    )

    transmission = subparsers.add_parser(
        "apply-transmission",
        help="Apply the current upload policy to Transmission's session upload limit.",
    )
    transmission.add_argument("--rpc-url", required=True, help="Transmission RPC URL.")
    transmission.add_argument(
        "--state-file", required=True, help="Path to the shared state JSON file."
    )
    transmission.add_argument("--interval-seconds", type=float, default=30.0)
    transmission.add_argument("--request-timeout-seconds", type=float, default=15.0)
    transmission.add_argument("--fallback-mbit", type=float, default=8.0)
    transmission.add_argument(
        "--transmission-headroom-fraction", type=float, default=0.95
    )
    transmission.add_argument("--public-group-fraction", type=float, default=0.4)
    transmission.add_argument("--max-state-age-seconds", type=float, default=90.0)

    tc_applier = subparsers.add_parser(
        "apply-tc",
        help="Apply the current upload policy to the WireGuard tc shaper.",
    )
    tc_applier.add_argument(
        "--state-file", required=True, help="Path to the shared state JSON file."
    )
    tc_applier.add_argument("--interval-seconds", type=float, default=30.0)
    tc_applier.add_argument("--fallback-mbit", type=float, default=8.0)
    tc_applier.add_argument(
        "--transmission-headroom-fraction", type=float, default=0.95
    )
    tc_applier.add_argument("--public-group-fraction", type=float, default=0.4)
    tc_applier.add_argument("--max-state-age-seconds", type=float, default=90.0)
    tc_applier.add_argument(
        "--outer-link-rate",
        required=True,
        help="Parent HTB class rate for non-WireGuard traffic.",
    )
    tc_applier.add_argument(
        "--endpoint-port", type=int, required=True, help="WireGuard UDP endpoint port."
    )
    tc_applier.add_argument("--route-probe-address", default="1.1.1.1")

    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.command == "decide":
        return run_decider(args)
    if args.command == "apply-transmission":
        return run_transmission_applier(args)
    if args.command == "apply-tc":
        return run_tc_applier(args)

    raise SystemExit(f"unknown command {args.command!r}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(0)
