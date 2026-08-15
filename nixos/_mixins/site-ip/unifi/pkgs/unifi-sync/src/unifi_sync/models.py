from __future__ import annotations

import argparse
import ipaddress
from dataclasses import dataclass


class Arguments(argparse.Namespace):
    mac: str | None
    ip: str | None
    hostname: str
    base_url: str
    site: str
    api_key: str
    network_id: str
    create_known_client: bool
    client_name: str
    usergroup_id: str
    insecure_tls: bool
    debug: bool
    dry_run: bool
    inventory_json: str
    no_reservations_update: bool
    no_create_known_clients: bool
    no_local_dns_record: bool
    dhcp_range_json: str
    no_dhcp_range_update: bool
    domain_name: str
    domain_search_json: str
    domain_search_option_json: str
    classless_static_routes_json: str
    no_classless_static_routes_update: bool
    classless_static_routes_option_json: str
    tftp_server: str
    bootfile: str
    no_netboot_update: bool
    dns_records_json: str
    no_dns_records_update: bool
    static_routes_json: str
    no_static_routes_update: bool


@dataclass(frozen=True)
class ReservationSpec:
    hostname: str | None
    mac: str
    fixed_ip: ipaddress.IPv4Address


@dataclass(frozen=True)
class DhcpRangeSpec:
    start: ipaddress.IPv4Address
    end: ipaddress.IPv4Address


@dataclass(frozen=True)
class NetworkDhcpSettingsSpec:
    dhcp_range: DhcpRangeSpec | None
    domain_name: str | None
    domain_search: tuple[str, ...] | None
    domain_search_option: DhcpCustomOptionSpec | None
    classless_static_routes: tuple[ClasslessStaticRouteSpec, ...] | None
    classless_static_routes_option: DhcpCustomOptionSpec | None
    tftp_server: str | None
    bootfile: str | None


@dataclass(frozen=True)
class StaticRouteSpec:
    name: str
    destination: ipaddress.IPv4Network
    next_hop: ipaddress.IPv4Address
    distance: int
    enabled: bool = True


@dataclass(frozen=True)
class ClasslessStaticRouteSpec:
    destination: ipaddress.IPv4Network
    next_hop: ipaddress.IPv4Address


@dataclass(frozen=True)
class DhcpCustomOptionSpec:
    code: int
    name: str
    option_type: str
    signed: bool
    encoding: str
