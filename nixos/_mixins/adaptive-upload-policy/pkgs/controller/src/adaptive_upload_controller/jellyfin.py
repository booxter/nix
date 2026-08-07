from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import ssl

import httpx
from prometheus_client.parser import text_string_to_metric_families

from .errors import ControllerError


DEFAULT_MEDIA_TYPES = frozenset(
    {
        "audio",
        "audiobook",
        "episode",
        "movie",
        "musicvideo",
        "trailer",
        "video",
    }
)


@dataclass(frozen=True)
class MediaStreamStats:
    total: int
    external: int
    external_bitrate_bps: int
    external_missing_bitrate: int


def normalize_remote_ip(
    endpoint: str,
) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
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


def build_https_context(
    ca_file: str | None,
    client_cert_file: str | None,
    client_key_file: str | None,
) -> ssl.SSLContext:
    try:
        context = ssl.create_default_context(cafile=ca_file or None)
        if client_cert_file or client_key_file:
            if not client_cert_file or not client_key_file:
                raise ControllerError("both client certificate and key must be configured together")
            context.load_cert_chain(client_cert_file, client_key_file)
    except (OSError, ssl.SSLError) as error:
        raise ControllerError(f"failed to build HTTPS client context: {error}") from error
    return context


def fetch_url_text(
    url: str,
    timeout_seconds: float,
    *,
    ca_file: str | None = None,
    client_cert_file: str | None = None,
    client_key_file: str | None = None,
) -> str:
    verify: ssl.SSLContext | bool = True
    if httpx.URL(url).scheme == "https":
        verify = build_https_context(ca_file, client_cert_file, client_key_file)
    try:
        with httpx.Client(verify=verify, timeout=timeout_seconds) as client:
            response = client.get(url)
            response.raise_for_status()
            return str(response.text)
    except httpx.HTTPError as error:
        raise ControllerError(f"request to {url} failed: {error}") from error


def collect_media_stream_stats(
    metrics_text: str,
    media_types: set[str] | frozenset[str],
) -> MediaStreamStats:
    external_sessions: set[tuple[str, str, str]] = set()
    playing_sessions: set[tuple[str, str, str]] = set()
    bitrate_by_session: dict[tuple[str, str, str], int] = {}

    for family in text_string_to_metric_families(metrics_text):
        for sample in family.samples:
            labels = sample.labels
            session = (
                labels.get("user_id", ""),
                labels.get("username", ""),
                labels.get("device", ""),
            )
            if sample.name == "jellyfin_user_active":
                if all(session) and not is_internal_remote_endpoint(labels.get("ip_address", "")):
                    external_sessions.add(session)
                continue

            media_type = labels.get("type", "").lower()
            if media_type not in media_types or not all(session):
                continue
            if sample.name == "jellyfin_now_playing_bitrate_bits_per_second":
                if sample.value > 0:
                    bitrate_by_session[session] = int(sample.value)
            elif sample.name == "jellyfin_now_playing_state" and sample.value > 0.5:
                playing_sessions.add(session)

    external_playing = playing_sessions & external_sessions
    external_bitrate_bps = 0
    external_missing_bitrate = 0
    for session in external_playing:
        bitrate_bps = bitrate_by_session.get(session)
        if bitrate_bps is None or bitrate_bps <= 0:
            external_missing_bitrate += 1
        else:
            external_bitrate_bps += bitrate_bps

    return MediaStreamStats(
        total=len(playing_sessions),
        external=len(external_playing),
        external_bitrate_bps=external_bitrate_bps,
        external_missing_bitrate=external_missing_bitrate,
    )
