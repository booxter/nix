import ipaddress
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import cast

from pydantic import BaseModel, ConfigDict


class TransmissionRpcError(RuntimeError):
    pass


class Tracker(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    host: str | None = None
    announce: str | None = None


class TransmissionRpcClient:
    def __init__(self, rpc_url: str, timeout_seconds: float) -> None:
        self.rpc_url = rpc_url
        self.timeout_seconds = timeout_seconds
        self.session_id: str | None = None
        self.next_request_id = 1

    def call(
        self,
        method: str,
        params: Mapping[str, object] | None = None,
    ) -> dict[str, object]:
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
                with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                    body = response.read().decode("utf-8")
            except urllib.error.HTTPError as exc:
                if exc.code == 409 and attempt == 0:
                    session_id = exc.headers.get("X-Transmission-Session-Id")
                    if session_id:
                        self.session_id = session_id
                        continue
                raise TransmissionRpcError(f"HTTP {exc.code} from Transmission RPC") from exc
            except (TimeoutError, urllib.error.URLError) as exc:
                raise TransmissionRpcError(f"request to Transmission RPC failed: {exc}") from exc

            try:
                parsed = json.loads(body)
            except json.JSONDecodeError as exc:
                raise TransmissionRpcError("Transmission RPC returned invalid JSON") from exc
            if not isinstance(parsed, dict):
                raise TransmissionRpcError("Transmission RPC returned invalid JSON-RPC payload")

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

            result: object = parsed.get("result", {})
            if not isinstance(result, dict):
                raise TransmissionRpcError("Transmission RPC returned invalid result payload")
            return cast(dict[str, object], result)

        raise TransmissionRpcError("failed to negotiate Transmission session id")


def normalize_tracker_host(raw_value: str) -> str:
    value = raw_value.strip()
    if not value:
        return ""

    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        pass

    if "://" in value:
        parsed = urllib.parse.urlparse(value)
        return normalize_tracker_host(parsed.hostname or "")

    if value.startswith("[") and "]" in value:
        return normalize_tracker_host(value[1 : value.index("]")])

    value = value.rsplit("@", 1)[-1]
    value = value.split("/", 1)[0]
    value = value.split(":", 1)[0]
    return value.lower().rstrip(".")


def read_tracker_aliases(trackers_file: Path) -> dict[str, str]:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("invalid tracker aliases")
            result[key] = value
        return result

    try:
        data = json.loads(trackers_file.read_text(), object_pairs_hook=unique_object)
        if not isinstance(data, dict):
            raise ValueError
        aliases: dict[str, str] = {}
        for alias, raw_host in data.items():
            if not isinstance(alias, str) or not alias.strip() or not isinstance(raw_host, str):
                raise ValueError
            host = raw_host.strip().lower()
            try:
                host = str(ipaddress.ip_address(host))
            except ValueError:
                labels = host.rstrip(".").split(".")
                if len(host) > 253 or any(
                    not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                    for label in labels
                ):
                    raise ValueError from None
                host = host.rstrip(".")
            if not host or host in aliases.values():
                raise ValueError
            aliases[alias] = host
        return aliases
    except (ValueError, UnicodeError):
        raise ValueError("invalid tracker aliases") from None


def trackers_match_hosts(trackers: Sequence[Tracker], tracker_hosts: set[str]) -> bool:
    for tracker in trackers:
        for raw_host in (tracker.host, tracker.announce):
            if raw_host is None:
                continue
            host = normalize_tracker_host(raw_host)
            if host and host in tracker_hosts:
                return True

    return False


def matching_tracker_aliases(trackers: Sequence[Tracker], aliases: Mapping[str, str]) -> set[str]:
    return {alias for alias, host in aliases.items() if trackers_match_hosts(trackers, {host})}
