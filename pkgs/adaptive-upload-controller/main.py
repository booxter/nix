#!/usr/bin/env python3

import argparse
import datetime
import ipaddress
import json
import logging
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
DEFAULT_VIDEO_TYPES = {
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
    return (
        datetime.datetime.now(datetime.timezone.utc)
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


def calculate_transmission_upload_limit_kbps(
    target_mbit: int, headroom_fraction: float
) -> int:
    return max(1, int((target_mbit * 1000.0 / 8.0) * headroom_fraction))


def calculate_public_group_limit_kbps(
    transmission_upload_limit_kbps: int, public_group_fraction: float
) -> int:
    return max(1, int(transmission_upload_limit_kbps * public_group_fraction))


def default_policy_state(
    fallback_mbit: int,
    transmission_headroom_fraction: float,
    public_group_fraction: float,
    reason: str,
    exporter_ok: bool,
    active_external_video_streams: int | None,
) -> dict:
    transmission_upload_limit_kbps = calculate_transmission_upload_limit_kbps(
        fallback_mbit, transmission_headroom_fraction
    )
    return {
        "active_external_video_streams": active_external_video_streams,
        "active_video_streams_total": active_external_video_streams,
        "exporter_ok": exporter_ok,
        "public_group_upload_limit_kbps": calculate_public_group_limit_kbps(
            transmission_upload_limit_kbps, public_group_fraction
        ),
        "reason": reason,
        "target_mbit": fallback_mbit,
        "target_tc_rate": f"{fallback_mbit}mbit",
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


def collect_video_stream_counts(
    metrics_text: str, video_types: set[str]
) -> tuple[int, int]:
    external_session_keys: set[tuple[str, str, str]] = set()
    playing_video_session_keys: list[tuple[str, str, str]] = []

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
        if media_type in video_types:
            session_key = (
                labels.get("user_id", ""),
                labels.get("username", ""),
                labels.get("device", ""),
            )
            if session_key[0] and session_key[1] and session_key[2]:
                playing_video_session_keys.append(session_key)

    total_streams = len(playing_video_session_keys)
    external_streams = sum(
        1
        for session_key in playing_video_session_keys
        if session_key in external_session_keys
    )
    return total_streams, external_streams


def decide_policy_state(args: argparse.Namespace) -> dict:
    try:
        metrics_text = fetch_url_text(args.exporter_url, args.request_timeout_seconds)
        total_video_streams, active_external_video_streams = (
            collect_video_stream_counts(metrics_text, set(args.video_types))
        )
        if active_external_video_streams == 0:
            target_mbit = args.no_streams_mbit
            reason = "no_active_video_streams"
        elif active_external_video_streams == 1:
            target_mbit = args.one_stream_mbit
            reason = "one_active_video_stream"
        else:
            target_mbit = args.many_streams_mbit
            reason = "multiple_active_video_streams"
        exporter_ok = True
    except ControllerError as exc:
        LOG.warning("using conservative fallback after exporter failure: %s", exc)
        target_mbit = args.many_streams_mbit
        total_video_streams = None
        active_external_video_streams = None
        reason = "exporter_unreachable"
        exporter_ok = False

    transmission_upload_limit_kbps = calculate_transmission_upload_limit_kbps(
        target_mbit, args.transmission_headroom_fraction
    )
    return {
        "active_external_video_streams": active_external_video_streams,
        "active_video_streams_total": total_video_streams,
        "exporter_ok": exporter_ok,
        "public_group_upload_limit_kbps": calculate_public_group_limit_kbps(
            transmission_upload_limit_kbps, args.public_group_fraction
        ),
        "reason": reason,
        "target_mbit": target_mbit,
        "target_tc_rate": f"{target_mbit}mbit",
        "transmission_upload_limit_kbps": transmission_upload_limit_kbps,
        "updated_at": now_utc_iso8601(),
    }


def load_policy_state(
    state_file: Path,
    fallback_mbit: int,
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
        active_external_video_streams=None,
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
        not isinstance(target_mbit, int)
        or target_mbit <= 0
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
            state = decide_policy_state(args)
            signature = (
                state["target_mbit"],
                state["transmission_upload_limit_kbps"],
                state["public_group_upload_limit_kbps"],
                state["active_external_video_streams"],
                state["active_video_streams_total"],
                state["reason"],
                state["exporter_ok"],
            )
            write_json_atomic(state_file, state)
            if signature != last_signature:
                LOG.info(
                    "policy updated: target_mbit=%s transmission_upload_limit_kbps=%s public_group_upload_limit_kbps=%s active_external_video_streams=%s active_video_streams_total=%s reason=%s exporter_ok=%s",
                    state["target_mbit"],
                    state["transmission_upload_limit_kbps"],
                    state["public_group_upload_limit_kbps"],
                    state["active_external_video_streams"],
                    state["active_video_streams_total"],
                    state["reason"],
                    state["exporter_ok"],
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
    outer_link_rate: str,
    endpoint_port: int,
) -> None:
    # Rebuild the tree on changes because `tc qdisc replace` on the existing
    # CAKE leaf returns "Change operation not supported by specified qdisc".
    run_command(["tc", "qdisc", "del", "dev", iface, "root"], check=False)

    commands = [
        [
            "tc",
            "qdisc",
            "add",
            "dev",
            iface,
            "root",
            "handle",
            "1:",
            "htb",
            "default",
            "20",
            "r2q",
            "1000",
        ],
        [
            "tc",
            "class",
            "add",
            "dev",
            iface,
            "parent",
            "1:",
            "classid",
            "1:1",
            "htb",
            "rate",
            outer_link_rate,
            "ceil",
            outer_link_rate,
        ],
        [
            "tc",
            "class",
            "add",
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
            "class",
            "add",
            "dev",
            iface,
            "parent",
            "1:1",
            "classid",
            "1:20",
            "htb",
            "rate",
            outer_link_rate,
            "ceil",
            outer_link_rate,
        ],
        [
            "tc",
            "qdisc",
            "add",
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
        [
            "tc",
            "qdisc",
            "add",
            "dev",
            iface,
            "parent",
            "1:20",
            "handle",
            "20:",
            "fq_codel",
        ],
        [
            "tc",
            "filter",
            "add",
            "dev",
            iface,
            "protocol",
            "ip",
            "parent",
            "1:",
            "prio",
            "10",
            "flower",
            "ip_proto",
            "udp",
            "dst_port",
            str(endpoint_port),
            "classid",
            "1:10",
        ],
        [
            "tc",
            "filter",
            "add",
            "dev",
            iface,
            "protocol",
            "ipv6",
            "parent",
            "1:",
            "prio",
            "11",
            "flower",
            "ip_proto",
            "udp",
            "dst_port",
            str(endpoint_port),
            "classid",
            "1:10",
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
                    outer_link_rate=args.outer_link_rate,
                    endpoint_port=args.endpoint_port,
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
    decider.add_argument("--no-streams-mbit", type=int, default=20)
    decider.add_argument("--one-stream-mbit", type=int, default=15)
    decider.add_argument("--many-streams-mbit", type=int, default=8)
    decider.add_argument("--transmission-headroom-fraction", type=float, default=0.95)
    decider.add_argument("--public-group-fraction", type=float, default=0.4)
    decider.add_argument(
        "--video-types",
        nargs="+",
        default=sorted(DEFAULT_VIDEO_TYPES),
        help="Jellyfin media types that count as active video streams.",
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
    transmission.add_argument("--fallback-mbit", type=int, default=8)
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
    tc_applier.add_argument("--fallback-mbit", type=int, default=8)
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
