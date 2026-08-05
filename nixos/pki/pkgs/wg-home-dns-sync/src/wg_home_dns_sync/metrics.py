from __future__ import annotations

import ipaddress
import math
from dataclasses import dataclass

from prometheus_client.parser import text_string_to_metric_families
from unifi_sync.dns import DnsRecordSpec

from .models import PeerDnsSpec, SyncError


HANDSHAKE_AGE_METRIC = "wireguard_latest_handshake_delay_seconds"
HANDSHAKE_TIME_METRIC = "wireguard_latest_handshake_seconds"


@dataclass(frozen=True)
class PeerStatus:
    public_key: str
    allowed_ips: tuple[str, ...]
    latest_handshake_seconds: int
    latest_handshake_age_seconds: int | None
    connected: bool


@dataclass
class _StatusAccumulator:
    allowed_ips: tuple[str, ...] = ()
    latest_handshake_seconds: int = 0
    latest_handshake_age_seconds: int | None = None


def build_status_by_public_key(
    metrics_text: str,
    now: int,
    handshake_max_age_seconds: int,
) -> dict[str, PeerStatus]:
    accumulators: dict[str, _StatusAccumulator] = {}
    seen_samples: set[tuple[str, str]] = set()
    try:
        families = text_string_to_metric_families(metrics_text)
        for family in families:
            for sample in family.samples:
                metric_name = sample.name
                if metric_name not in (HANDSHAKE_AGE_METRIC, HANDSHAKE_TIME_METRIC):
                    continue

                public_key = sample.labels.get("public_key")
                if not public_key:
                    raise SyncError(f"{metric_name} is missing public_key label")

                sample_key = (metric_name, public_key)
                if sample_key in seen_samples:
                    raise SyncError(
                        f"WireGuard metrics have duplicate {metric_name} sample for {public_key}"
                    )
                seen_samples.add(sample_key)

                value = float(sample.value)
                if not math.isfinite(value):
                    raise SyncError(f"WireGuard metric {metric_name} value is not finite")
                metric_value = int(value)

                accumulator = accumulators.setdefault(public_key, _StatusAccumulator())
                allowed_ips = tuple(
                    item.strip()
                    for item in sample.labels.get("allowed_ips", "").split(",")
                    if item.strip()
                )
                if allowed_ips and not accumulator.allowed_ips:
                    accumulator.allowed_ips = allowed_ips

                if metric_name == HANDSHAKE_TIME_METRIC:
                    accumulator.latest_handshake_seconds = metric_value
                else:
                    accumulator.latest_handshake_age_seconds = max(0, metric_value)
    except ValueError as error:
        raise SyncError(f"invalid Prometheus metrics: {error}") from error

    if not accumulators:
        raise SyncError("WireGuard metrics did not include latest handshake samples")

    statuses: dict[str, PeerStatus] = {}
    for public_key, accumulator in accumulators.items():
        age = accumulator.latest_handshake_age_seconds
        if age is None and accumulator.latest_handshake_seconds > 0:
            age = max(0, now - accumulator.latest_handshake_seconds)
        connected = age is not None and age <= handshake_max_age_seconds
        if accumulator.latest_handshake_seconds <= 0 and HANDSHAKE_TIME_METRIC in {
            metric_name for metric_name, key in seen_samples if key == public_key
        }:
            connected = False
        statuses[public_key] = PeerStatus(
            public_key=public_key,
            allowed_ips=accumulator.allowed_ips,
            latest_handshake_seconds=accumulator.latest_handshake_seconds,
            latest_handshake_age_seconds=age,
            connected=connected,
        )
    return statuses


def allowed_ips_contain_address(
    allowed_ips: tuple[str, ...],
    address: ipaddress.IPv4Address,
) -> bool:
    for allowed_ip in allowed_ips:
        try:
            if ipaddress.ip_interface(allowed_ip).ip == address:
                return True
        except ValueError as error:
            raise SyncError(f"WireGuard metric has invalid allowed IP: {allowed_ip}") from error
    return False


def build_dns_records(
    peer_specs: list[PeerDnsSpec],
    status_by_public_key: dict[str, PeerStatus],
    ttl_seconds: int,
) -> list[DnsRecordSpec]:
    records: list[DnsRecordSpec] = []
    for peer in peer_specs:
        status = status_by_public_key.get(peer.public_key)
        if status is None:
            raise SyncError(f"WireGuard metrics are missing peer: {peer.name}")
        if status.allowed_ips and not allowed_ips_contain_address(status.allowed_ips, peer.address):
            raise SyncError(
                f"WireGuard metrics allowed IPs for {peer.name} do not include {peer.address}"
            )
        records.append(
            DnsRecordSpec(
                record_type="A_RECORD",
                domain=peer.domain,
                ttl_seconds=ttl_seconds,
                ipv4_address=peer.address,
                enabled=status.connected,
            )
        )
    return records
