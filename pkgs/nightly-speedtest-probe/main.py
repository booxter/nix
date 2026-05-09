#!/usr/bin/env python3

import argparse
import json
import logging
import os
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


LOG = logging.getLogger("nightly-speedtest-probe")
PROMETHEUS_SAMPLE_RE_TEMPLATE = (
    r"^{metric}(?:\{{(?P<labels>.*)\}})?\s+"
    r"(?P<value>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)"
    r"(?:\s+\d+)?$"
)
LABEL_PAIR_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"')
SABNZBD_PAUSED_METRIC_RE = re.compile(
    PROMETHEUS_SAMPLE_RE_TEMPLATE.format(metric="sabnzbd_paused")
)
SABNZBD_QUEUE_DOWNLOAD_RATE_METRIC_RE = re.compile(
    PROMETHEUS_SAMPLE_RE_TEMPLATE.format(
        metric="sabnzbd_queue_download_rate_bytes_per_second"
    )
)


class ProbeError(RuntimeError):
    pass


class TransmissionRpcError(RuntimeError):
    pass


class SabnzbdError(RuntimeError):
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


def write_text_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def fetch_text(url: str, timeout_seconds: float) -> str:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return response.read().decode("utf-8")
    except (TimeoutError, socket.timeout, urllib.error.URLError) as exc:
        raise ProbeError(f"request to {url} failed: {exc}") from exc


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


def parse_prometheus_metric_value(
    metric_re: re.Pattern[str],
    text: str,
    required_labels: dict[str, str] | None = None,
) -> float | None:
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = metric_re.match(line)
        if match is None:
            continue
        labels = parse_prometheus_labels(match.group("labels") or "")
        if required_labels is not None and any(
            labels.get(key) != value for key, value in required_labels.items()
        ):
            continue
        try:
            return float(match.group("value"))
        except ValueError:
            continue
    return None


def read_secret(path: Path) -> str:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ProbeError(f"failed to read secret file {path}: {exc}") from exc
    if not value:
        raise ProbeError(f"secret file {path} is empty")
    return value


def load_sabnzbd_drain_state(
    exporter_url: str,
    timeout_seconds: float,
    exporter_instance: str | None,
) -> dict[str, int | bool]:
    required_labels = None
    if exporter_instance is not None:
        required_labels = {"sabnzbd_instance": exporter_instance}

    metrics_text = fetch_text(exporter_url, timeout_seconds)
    paused_value = parse_prometheus_metric_value(
        SABNZBD_PAUSED_METRIC_RE,
        metrics_text,
        required_labels,
    )
    download_rate_value = parse_prometheus_metric_value(
        SABNZBD_QUEUE_DOWNLOAD_RATE_METRIC_RE,
        metrics_text,
        required_labels,
    )

    if paused_value is None:
        raise ProbeError("SABnzbd exporter did not expose sabnzbd_paused")

    return {
        "paused": paused_value >= 0.5,
        "download_rate_bytes_per_second": max(
            0,
            int(round(0.0 if download_rate_value is None else download_rate_value)),
        ),
    }


def sabnzbd_api_call(
    api_url: str,
    api_key: str,
    mode: str,
    timeout_seconds: float,
) -> None:
    query = urllib.parse.urlencode(
        {
            "apikey": api_key,
            "mode": mode,
            "output": "json",
        }
    )
    separator = "&" if "?" in api_url else "?"
    url = f"{api_url}{separator}{query}"
    body = fetch_text(url, timeout_seconds).strip()
    if body == "":
        return

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        raise SabnzbdError(f"SABnzbd returned invalid JSON for mode={mode!r}") from exc

    if not isinstance(parsed, dict):
        return

    error_value = parsed.get("error")
    if isinstance(error_value, str) and error_value.strip():
        raise SabnzbdError(f"SABnzbd API mode={mode!r} returned error {error_value!r}")

    status_value = parsed.get("status")
    if isinstance(status_value, bool) and not status_value:
        raise SabnzbdError(f"SABnzbd API mode={mode!r} reported failure")
    if isinstance(status_value, str) and status_value.lower() == "false":
        raise SabnzbdError(f"SABnzbd API mode={mode!r} reported failure")


def rpc_stop_all_torrents(client: TransmissionRpcClient) -> None:
    client.call("torrent-stop")


def rpc_start_all_torrents(client: TransmissionRpcClient) -> None:
    client.call("torrent-start")


def rpc_get_transfer_rates(client: TransmissionRpcClient) -> dict[str, int]:
    arguments = client.call(
        "torrent-get",
        {
            "fields": [
                "rateDownload",
                "rateUpload",
            ]
        },
    )
    torrents = arguments.get("torrents", [])
    if not isinstance(torrents, list):
        raise TransmissionRpcError("Transmission RPC returned an invalid torrent list")

    download_rate_bytes_per_second = 0
    upload_rate_bytes_per_second = 0
    for torrent in torrents:
        if not isinstance(torrent, dict):
            continue
        rate_download = torrent.get("rateDownload")
        rate_upload = torrent.get("rateUpload")
        if isinstance(rate_download, int) and rate_download > 0:
            download_rate_bytes_per_second += rate_download
        if isinstance(rate_upload, int) and rate_upload > 0:
            upload_rate_bytes_per_second += rate_upload

    return {
        "download_rate_bytes_per_second": download_rate_bytes_per_second,
        "upload_rate_bytes_per_second": upload_rate_bytes_per_second,
    }


def wait_for_traffic_drain(
    *,
    client: TransmissionRpcClient,
    sabnzbd_exporter_url: str,
    sabnzbd_exporter_instance: str | None,
    timeout_seconds: float,
    poll_seconds: float,
    request_timeout_seconds: float,
) -> None:
    started_at = time.monotonic()
    deadline = started_at + timeout_seconds
    sleep_seconds = max(0.1, poll_seconds)

    while True:
        sabnzbd_state = load_sabnzbd_drain_state(
            exporter_url=sabnzbd_exporter_url,
            timeout_seconds=request_timeout_seconds,
            exporter_instance=sabnzbd_exporter_instance,
        )
        transmission_rates = rpc_get_transfer_rates(client)

        sabnzbd_drained = (
            bool(sabnzbd_state["paused"])
            and int(sabnzbd_state["download_rate_bytes_per_second"]) == 0
        )
        transmission_drained = (
            transmission_rates["download_rate_bytes_per_second"] == 0
            and transmission_rates["upload_rate_bytes_per_second"] == 0
        )

        if sabnzbd_drained and transmission_drained:
            LOG.info(
                "traffic drained after %.1fs",
                time.monotonic() - started_at,
            )
            return

        if time.monotonic() >= deadline:
            raise ProbeError(
                "timed out waiting for downloader traffic to drain "
                f"(sab_paused={sabnzbd_state['paused']}, "
                f"sab_download_bps={sabnzbd_state['download_rate_bytes_per_second']}, "
                f"transmission_download_bps={transmission_rates['download_rate_bytes_per_second']}, "
                f"transmission_upload_bps={transmission_rates['upload_rate_bytes_per_second']})"
            )

        time.sleep(sleep_seconds)


def restore_everything(
    *,
    client: TransmissionRpcClient,
    sabnzbd_api_url: str,
    sabnzbd_api_key: str,
    timeout_seconds: float,
) -> list[str]:
    failures: list[str] = []

    try:
        rpc_start_all_torrents(client)
        LOG.info("started all Transmission torrents after nightly speedtest")
    except TransmissionRpcError as exc:
        failures.append(f"Transmission resume failed: {exc}")
        LOG.error("failed to start Transmission torrents: %s", exc)

    try:
        sabnzbd_api_call(
            api_url=sabnzbd_api_url,
            api_key=sabnzbd_api_key,
            mode="resume",
            timeout_seconds=timeout_seconds,
        )
        LOG.info("resumed SABnzbd after nightly speedtest")
    except SabnzbdError as exc:
        failures.append(f"SABnzbd resume failed: {exc}")
        LOG.error("failed to resume SABnzbd: %s", exc)

    return failures


def nonnegative_float(value: object) -> float:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        numeric = float(value)
        if numeric >= 0:
            return numeric
    return 0.0


def default_probe_result(scope: str) -> dict[str, object]:
    return {
        "scope": scope,
        "success": 0.0,
        "download_bits_per_second": 0.0,
        "upload_bits_per_second": 0.0,
        "latency_milliseconds": 0.0,
        "duration_seconds": 0.0,
        "last_run_timestamp_seconds": time.time(),
        "server_id": "",
        "server_name": "",
        "server_sponsor": "",
        "server_country": "",
        "client_ip": "",
        "client_isp": "",
        "error": "",
    }


def parse_ookla_result(parsed: dict[str, object]) -> dict[str, object]:
    ping = parsed.get("ping")
    if not isinstance(ping, dict):
        ping = {}
    download = parsed.get("download")
    if not isinstance(download, dict):
        download = {}
    upload = parsed.get("upload")
    if not isinstance(upload, dict):
        upload = {}
    server = parsed.get("server")
    if not isinstance(server, dict):
        server = {}
    interface = parsed.get("interface")
    if not isinstance(interface, dict):
        interface = {}

    server_name = str(server.get("location") or server.get("name") or "")
    server_sponsor = str(server.get("name") or server.get("host") or "")

    return {
        "success": 1.0,
        "download_bits_per_second": nonnegative_float(download.get("bandwidth")) * 8.0,
        "upload_bits_per_second": nonnegative_float(upload.get("bandwidth")) * 8.0,
        "latency_milliseconds": nonnegative_float(ping.get("latency")),
        "server_id": str(server.get("id", "")),
        "server_name": server_name,
        "server_sponsor": server_sponsor,
        "server_country": str(server.get("country", "")),
        "client_ip": str(interface.get("externalIp") or ""),
        "client_isp": str(parsed.get("isp") or ""),
        "error": "",
    }


def parse_legacy_speedtest_cli_result(parsed: dict[str, object]) -> dict[str, object]:
    server = parsed.get("server")
    if not isinstance(server, dict):
        server = {}
    client = parsed.get("client")
    if not isinstance(client, dict):
        client = {}

    return {
        "success": 1.0,
        "download_bits_per_second": nonnegative_float(parsed.get("download")),
        "upload_bits_per_second": nonnegative_float(parsed.get("upload")),
        "latency_milliseconds": nonnegative_float(parsed.get("ping")),
        "server_id": str(server.get("id", "")),
        "server_name": str(server.get("name", "")),
        "server_sponsor": str(server.get("sponsor", "")),
        "server_country": str(server.get("country", "")),
        "client_ip": str(client.get("ip", "")),
        "client_isp": str(client.get("isp", "")),
        "error": "",
    }


def parse_librespeed_result(
    parsed: list[object],
    configured_server_id: str,
) -> dict[str, object]:
    if not parsed:
        raise ProbeError("speedtest returned an empty JSON array")
    result = parsed[0]
    if not isinstance(result, dict):
        raise ProbeError("speedtest returned an invalid LibreSpeed JSON payload")

    server = result.get("server")
    if not isinstance(server, dict):
        server = {}
    client = result.get("client")
    if not isinstance(client, dict):
        client = {}

    return {
        "success": 1.0,
        "download_bits_per_second": nonnegative_float(result.get("download"))
        * 1000000.0,
        "upload_bits_per_second": nonnegative_float(result.get("upload")) * 1000000.0,
        "latency_milliseconds": nonnegative_float(result.get("ping")),
        "server_id": configured_server_id,
        "server_name": str(server.get("name", "")),
        "server_sponsor": str(server.get("url", "")),
        "server_country": "",
        "client_ip": str(client.get("ip", "")),
        "client_isp": str(client.get("org", "")),
        "error": "",
    }


def run_speedtest_command(
    *,
    scope: str,
    command: list[str],
    timeout_seconds: float,
    configured_server_id: str,
) -> dict[str, object]:
    started_at = time.time()
    result = default_probe_result(scope)
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        result["duration_seconds"] = time.time() - started_at
        result["last_run_timestamp_seconds"] = time.time()
        result["error"] = f"speedtest timed out after {timeout_seconds:.0f}s"
        raise ProbeError(result["error"]) from exc

    result["duration_seconds"] = time.time() - started_at
    result["last_run_timestamp_seconds"] = time.time()
    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()

    if completed.returncode != 0:
        error_detail = stderr or stdout or f"exit status {completed.returncode}"
        result["error"] = f"speedtest failed: {error_detail}"
        raise ProbeError(result["error"])

    if stdout == "":
        result["error"] = "speedtest returned empty stdout"
        raise ProbeError(result["error"])

    try:
        parsed = json.loads(stdout)
    except json.JSONDecodeError as exc:
        result["error"] = "speedtest returned invalid JSON"
        raise ProbeError(result["error"]) from exc

    if isinstance(parsed, list):
        result.update(
            parse_librespeed_result(
                parsed,
                configured_server_id=configured_server_id,
            )
        )
    elif isinstance(parsed, dict):
        if isinstance(parsed.get("download"), dict) or parsed.get("type") == "result":
            result.update(parse_ookla_result(parsed))
        else:
            result.update(parse_legacy_speedtest_cli_result(parsed))
    else:
        result["error"] = "speedtest returned an unsupported JSON payload"
        raise ProbeError(result["error"])
    return result


def escape_prometheus_label_value(value: str) -> str:
    return value.replace("\\", r"\\").replace("\n", r"\n").replace('"', r"\"")


def render_metrics(results: dict[str, dict[str, object]]) -> str:
    lines = [
        "# HELP host_observability_speedtest_probe_success Whether the latest scheduled speedtest probe succeeded for this scope.",
        "# TYPE host_observability_speedtest_probe_success gauge",
        "# HELP host_observability_speedtest_probe_download_bits_per_second Latest measured download throughput in bits per second for this scope.",
        "# TYPE host_observability_speedtest_probe_download_bits_per_second gauge",
        "# HELP host_observability_speedtest_probe_upload_bits_per_second Latest measured upload throughput in bits per second for this scope.",
        "# TYPE host_observability_speedtest_probe_upload_bits_per_second gauge",
        "# HELP host_observability_speedtest_probe_latency_milliseconds Latest measured round-trip latency in milliseconds for this scope.",
        "# TYPE host_observability_speedtest_probe_latency_milliseconds gauge",
        "# HELP host_observability_speedtest_probe_duration_seconds Wall-clock duration of the latest speedtest command for this scope.",
        "# TYPE host_observability_speedtest_probe_duration_seconds gauge",
        "# HELP host_observability_speedtest_probe_last_run_timestamp_seconds Unix timestamp when the latest speedtest command for this scope finished.",
        "# TYPE host_observability_speedtest_probe_last_run_timestamp_seconds gauge",
        "# HELP host_observability_speedtest_probe_info Metadata about the latest successful speedtest probe for this scope.",
        "# TYPE host_observability_speedtest_probe_info gauge",
    ]

    for scope, result in sorted(results.items()):
        labels = f'scope="{escape_prometheus_label_value(scope)}"'
        lines.append(
            f"host_observability_speedtest_probe_success{{{labels}}} {result['success']}"
        )
        lines.append(
            f"host_observability_speedtest_probe_download_bits_per_second{{{labels}}} {result['download_bits_per_second']}"
        )
        lines.append(
            f"host_observability_speedtest_probe_upload_bits_per_second{{{labels}}} {result['upload_bits_per_second']}"
        )
        lines.append(
            f"host_observability_speedtest_probe_latency_milliseconds{{{labels}}} {result['latency_milliseconds']}"
        )
        lines.append(
            f"host_observability_speedtest_probe_duration_seconds{{{labels}}} {result['duration_seconds']}"
        )
        lines.append(
            f"host_observability_speedtest_probe_last_run_timestamp_seconds{{{labels}}} {result['last_run_timestamp_seconds']}"
        )
        if float(result["success"]) >= 0.5:
            info_labels = (
                f"{labels},"
                f'server_id="{escape_prometheus_label_value(str(result["server_id"]))}",'
                f'server_name="{escape_prometheus_label_value(str(result["server_name"]))}",'
                f'server_sponsor="{escape_prometheus_label_value(str(result["server_sponsor"]))}",'
                f'server_country="{escape_prometheus_label_value(str(result["server_country"]))}",'
                f'client_ip="{escape_prometheus_label_value(str(result["client_ip"]))}",'
                f'client_isp="{escape_prometheus_label_value(str(result["client_isp"]))}"'
            )
            lines.append(f"host_observability_speedtest_probe_info{{{info_labels}}} 1")

    return "\n".join(lines) + "\n"


def build_probe_commands(args: argparse.Namespace) -> dict[str, list[str]]:
    wan_command = [
        args.speedtest_command,
        "--json",
        "--no-icmp",
        "--timeout",
        str(int(args.request_timeout_seconds)),
    ]
    if args.wan_server_id:
        wan_command.extend(["--server", args.wan_server_id])

    wg_command = [
        "ip",
        "netns",
        "exec",
        args.wg_namespace_name,
        args.speedtest_command,
        "--json",
        "--no-icmp",
        "--timeout",
        str(int(args.request_timeout_seconds)),
    ]
    if args.wg_server_id:
        wg_command.extend(["--server", args.wg_server_id])

    return {
        "wan": wan_command,
        "wg": wg_command,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run nightly direct and WireGuard speedtests with local downloader quiescing."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run")
    run.add_argument("--metrics-file", required=True)
    run.add_argument("--speedtest-command", required=True)
    run.add_argument("--wg-namespace-name", required=True)
    run.add_argument("--transmission-rpc-url", required=True)
    run.add_argument("--sabnzbd-api-url", required=True)
    run.add_argument("--sabnzbd-api-key-file", required=True)
    run.add_argument("--sabnzbd-exporter-url", required=True)
    run.add_argument("--sabnzbd-exporter-instance", default="")
    run.add_argument("--wan-server-id", default="")
    run.add_argument("--wg-server-id", default="")
    run.add_argument("--request-timeout-seconds", type=float, default=20.0)
    run.add_argument("--speedtest-timeout-seconds", type=float, default=180.0)
    run.add_argument("--drain-timeout-seconds", type=float, default=60.0)
    run.add_argument("--drain-poll-seconds", type=float, default=1.0)
    run.add_argument("--post-drain-settle-seconds", type=float, default=0.0)
    run.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )

    restore = subparsers.add_parser("restore")
    restore.add_argument("--transmission-rpc-url", required=True)
    restore.add_argument("--sabnzbd-api-url", required=True)
    restore.add_argument("--sabnzbd-api-key-file", required=True)
    restore.add_argument("--request-timeout-seconds", type=float, default=20.0)
    restore.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )
    return parser.parse_args()


def run_main(args: argparse.Namespace) -> int:
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    speedtest_path = Path(args.speedtest_command)
    if not speedtest_path.is_file():
        raise SystemExit(f"speedtest binary is missing: {speedtest_path}")

    client = TransmissionRpcClient(
        rpc_url=args.transmission_rpc_url,
        timeout_seconds=args.request_timeout_seconds,
    )
    sab_api_key = read_secret(Path(args.sabnzbd_api_key_file))
    sab_exporter_instance = args.sabnzbd_exporter_instance.strip() or None

    results = {
        "wan": default_probe_result("wan"),
        "wg": default_probe_result("wg"),
    }

    failure = False

    try:
        sabnzbd_api_call(
            api_url=args.sabnzbd_api_url,
            api_key=sab_api_key,
            mode="pause",
            timeout_seconds=args.request_timeout_seconds,
        )
        LOG.info("paused SABnzbd for nightly speedtest")

        rpc_stop_all_torrents(client)
        LOG.info("stopped all Transmission torrents for nightly speedtest")

        wait_for_traffic_drain(
            client=client,
            sabnzbd_exporter_url=args.sabnzbd_exporter_url,
            sabnzbd_exporter_instance=sab_exporter_instance,
            timeout_seconds=args.drain_timeout_seconds,
            poll_seconds=args.drain_poll_seconds,
            request_timeout_seconds=args.request_timeout_seconds,
        )
        if args.post_drain_settle_seconds > 0:
            LOG.info(
                "waiting %.1fs after drain before running speedtests",
                args.post_drain_settle_seconds,
            )
            time.sleep(args.post_drain_settle_seconds)

        for scope, command in build_probe_commands(args).items():
            try:
                results[scope] = run_speedtest_command(
                    scope=scope,
                    command=command,
                    timeout_seconds=args.speedtest_timeout_seconds,
                    configured_server_id=(
                        args.wan_server_id if scope == "wan" else args.wg_server_id
                    ),
                )
                LOG.info(
                    "%s speedtest complete: download=%.2f Mbps upload=%.2f Mbps latency=%.2f ms server=%s / %s",
                    scope,
                    float(results[scope]["download_bits_per_second"]) / 1000000.0,
                    float(results[scope]["upload_bits_per_second"]) / 1000000.0,
                    float(results[scope]["latency_milliseconds"]),
                    results[scope]["server_sponsor"],
                    results[scope]["server_name"],
                )
            except ProbeError as exc:
                failure = True
                results[scope]["error"] = str(exc)
                LOG.warning("%s speedtest failed: %s", scope, exc)
    except (ProbeError, TransmissionRpcError, SabnzbdError) as exc:
        failure = True
        for result in results.values():
            result["last_run_timestamp_seconds"] = time.time()
            result["error"] = str(exc)
        LOG.error("nightly speedtest probe aborted before measurement: %s", exc)
    finally:
        restore_failures = restore_everything(
            client=client,
            sabnzbd_api_url=args.sabnzbd_api_url,
            sabnzbd_api_key=sab_api_key,
            timeout_seconds=args.request_timeout_seconds,
        )
        write_text_atomic(Path(args.metrics_file), render_metrics(results))

    if restore_failures:
        failure = True
    if any(float(result["success"]) < 0.5 for result in results.values()):
        failure = True

    return 1 if failure else 0


def restore_main(args: argparse.Namespace) -> int:
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    client = TransmissionRpcClient(
        rpc_url=args.transmission_rpc_url,
        timeout_seconds=args.request_timeout_seconds,
    )
    sab_api_key = read_secret(Path(args.sabnzbd_api_key_file))
    failures = restore_everything(
        client=client,
        sabnzbd_api_url=args.sabnzbd_api_url,
        sabnzbd_api_key=sab_api_key,
        timeout_seconds=args.request_timeout_seconds,
    )
    return 1 if failures else 0


def main() -> int:
    args = parse_args()
    if args.command == "run":
        return run_main(args)
    return restore_main(args)


if __name__ == "__main__":
    raise SystemExit(main())
