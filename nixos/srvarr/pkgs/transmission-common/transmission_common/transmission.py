from collections.abc import Callable
import json
import socket
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class TransmissionRpcError(RuntimeError):
    pass


class TransmissionRpcClient:
    def __init__(self, rpc_url: str, timeout_seconds: float) -> None:
        self.rpc_url = rpc_url
        self.timeout_seconds = timeout_seconds
        self.session_id: str | None = None
        self.next_request_id = 1

    def call(self, method: str, params: dict | None = None) -> dict:
        request_id = self.next_request_id
        self.next_request_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "method": method,
                "params": params or {},
                "id": request_id,
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
            if not isinstance(parsed, dict):
                raise TransmissionRpcError(
                    "Transmission RPC returned invalid JSON-RPC payload"
                )

            if parsed.get("id") != request_id:
                raise TransmissionRpcError("Transmission RPC returned mismatched id")

            error = parsed.get("error")
            if error is not None:
                if isinstance(error, dict):
                    message = error.get("message", "unknown error")
                    data = error.get("data")
                    if isinstance(data, dict) and data.get("error_string"):
                        message = f"{message}: {data['error_string']}"
                    raise TransmissionRpcError(
                        f"Transmission RPC returned error {error.get('code')}: {message}"
                    )
                raise TransmissionRpcError(f"Transmission RPC returned {error!r}")

            result = parsed.get("result", {})
            if not isinstance(result, dict):
                raise TransmissionRpcError(
                    "Transmission RPC returned invalid result payload"
                )
            return result

        raise TransmissionRpcError("failed to negotiate Transmission session id")


def normalize_tracker_host(raw_value: str) -> str:
    value = raw_value.strip()
    if not value:
        return ""

    if "://" in value:
        parsed = urllib.parse.urlparse(value)
        return (parsed.hostname or "").lower()

    if value.startswith("[") and "]" in value:
        return value[1 : value.index("]")].lower()

    value = value.rsplit("@", 1)[-1]
    value = value.split("/", 1)[0]
    value = value.split(":", 1)[0]
    return value.lower()


def read_tracker_hosts(
    trackers_file: Path,
    *,
    on_empty_entry: Callable[[int], None] | None = None,
) -> set[str]:
    lines = trackers_file.read_text().splitlines()
    hosts: set[str] = set()

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        host = normalize_tracker_host(line)
        if host:
            hosts.add(host)
        elif on_empty_entry is not None:
            on_empty_entry(line_number)

    return hosts


def torrent_matches_tracker_hosts(torrent: dict, tracker_hosts: set[str]) -> bool:
    for tracker in torrent.get("tracker_stats", []):
        if not isinstance(tracker, dict):
            continue
        host = normalize_tracker_host(str(tracker.get("host", "")))
        if host and host in tracker_hosts:
            return True

        announce = tracker.get("announce")
        if isinstance(announce, str):
            host = normalize_tracker_host(announce)
            if host and host in tracker_hosts:
                return True

    return False
