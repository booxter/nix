from __future__ import annotations

import argparse
import os


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="unifi-sync",
        description=(
            "Sync UniFi reservations, DHCP settings, and split-DNS records from inventory. "
            "Reservations still use the legacy UniFi OS API; DNS policies use the supported "
            "UniFi integration API."
        ),
    )
    parser.add_argument("--mac", help="Client MAC address for single-client mode.")
    parser.add_argument("--ip", help="Fixed IPv4 address for single-client mode.")
    parser.add_argument(
        "--hostname",
        default="",
        help="Optional Local DNS Record hostname for single-client mode.",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("UNIFI_BASE_URL", ""),
        help="UniFi base URL, for example https://unifi or https://192.168.0.1. Defaults to UNIFI_BASE_URL.",
    )
    parser.add_argument(
        "--site",
        default=os.environ.get("UNIFI_SITE", "default"),
        help="UniFi site short name. Defaults to UNIFI_SITE or 'default'.",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("UNIFI_API_KEY", ""),
        help="UniFi API key. Defaults to UNIFI_API_KEY.",
    )
    parser.add_argument(
        "--network-id",
        default="",
        help="Optional network _id. If omitted, the app matches each reservation by IP subnet.",
    )
    parser.add_argument(
        "--create-known-client",
        action="store_true",
        help="Create a known-client placeholder when a single-client MAC does not already exist.",
    )
    parser.add_argument(
        "--client-name",
        default="reservation-test",
        help="Optional client alias used when --create-known-client creates a placeholder record.",
    )
    parser.add_argument(
        "--usergroup-id",
        default="",
        help="Optional UniFi user group _id used for known-client creation.",
    )
    parser.add_argument(
        "--insecure-tls",
        action="store_true",
        help="Disable UniFi TLS certificate verification. Intended only for temporary local troubleshooting.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Print request flow details.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show planned UniFi changes without applying them.",
    )
    parser.add_argument(
        "--inventory-json",
        default=os.environ.get("UNIFI_RESERVATION_INVENTORY_JSON", ""),
        help=(
            "JSON array of inventory reservations. If --mac/--ip are omitted, the app uses this "
            "to sync all MAC-backed entries. Defaults to UNIFI_RESERVATION_INVENTORY_JSON."
        ),
    )
    parser.add_argument(
        "--no-reservations-update",
        action="store_true",
        help="Do not update UniFi known-client reservations.",
    )
    parser.add_argument(
        "--no-create-known-clients",
        action="store_true",
        help="Do not create placeholder known clients for missing inventory MACs.",
    )
    parser.add_argument(
        "--no-local-dns-record",
        action="store_true",
        help="Do not touch the Local DNS Record field.",
    )
    parser.add_argument(
        "--dhcp-range-json",
        default=os.environ.get("UNIFI_NETWORK_DHCP_RANGE_JSON", ""),
        help=(
            "Optional JSON object with start/end DHCP addresses for the target network. "
            "Defaults to UNIFI_NETWORK_DHCP_RANGE_JSON."
        ),
    )
    parser.add_argument(
        "--no-dhcp-range-update",
        action="store_true",
        help="Do not update the network DHCP range.",
    )
    parser.add_argument(
        "--domain-name",
        default=os.environ.get("UNIFI_NETWORK_DOMAIN_NAME", ""),
        help=(
            "Optional DHCP domain name for the target network. Defaults to "
            "UNIFI_NETWORK_DOMAIN_NAME."
        ),
    )
    parser.add_argument(
        "--domain-search-json",
        default=os.environ.get("UNIFI_NETWORK_DOMAIN_SEARCH_JSON", ""),
        help=(
            "Optional JSON string or array of DHCP domain-search suffixes. Defaults to "
            "UNIFI_NETWORK_DOMAIN_SEARCH_JSON."
        ),
    )
    parser.add_argument(
        "--domain-search-option-json",
        default=os.environ.get("UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_JSON", ""),
        help=(
            "Optional JSON object describing the custom DHCP option definition used to carry "
            "the domain-search list, for example "
            '{"code":119,"name":"DomainSearch","type":"text","signed":false,"encoding":"text"}. '
            "Defaults to UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_JSON."
        ),
    )
    parser.add_argument(
        "--classless-static-routes-json",
        default=os.environ.get("UNIFI_CLASSLESS_STATIC_ROUTES_JSON", ""),
        help=(
            "Optional JSON array of RFC 3442 classless static routes to publish via DHCP option 121. "
            "Defaults to UNIFI_CLASSLESS_STATIC_ROUTES_JSON."
        ),
    )
    parser.add_argument(
        "--no-classless-static-routes-update",
        action="store_true",
        help="Do not update DHCP option 121 classless static routes.",
    )
    parser.add_argument(
        "--classless-static-routes-option-json",
        default=os.environ.get("UNIFI_CLASSLESS_STATIC_ROUTES_OPTION_JSON", ""),
        help=(
            "Optional UniFi custom DHCP option definition for classless static routes, for example "
            '{"code":121,"name":"ClasslessStaticRoutes","type":"text","signed":false,"encoding":"text"}. '
            "Defaults to UNIFI_CLASSLESS_STATIC_ROUTES_OPTION_JSON."
        ),
    )
    parser.add_argument(
        "--tftp-server",
        default=os.environ.get("UNIFI_NETWORK_TFTP_SERVER", ""),
        help=(
            "Optional TFTP server hostname or IPv4 address for DHCP option 66. "
            "Defaults to UNIFI_NETWORK_TFTP_SERVER."
        ),
    )
    parser.add_argument(
        "--bootfile",
        default=os.environ.get("UNIFI_NETWORK_BOOTFILE", ""),
        help=(
            "Optional network-boot filename for DHCP option 67. Defaults to "
            "UNIFI_NETWORK_BOOTFILE."
        ),
    )
    parser.add_argument(
        "--no-netboot-update",
        action="store_true",
        help="Do not update DHCP options 66 and 67 for network boot.",
    )
    parser.add_argument(
        "--dns-records-json",
        default=os.environ.get("UNIFI_DNS_RECORDS_JSON", ""),
        help=(
            "Optional JSON array of DNS records to upsert through the supported UniFi DNS "
            "policy API. Defaults to UNIFI_DNS_RECORDS_JSON."
        ),
    )
    parser.add_argument(
        "--no-dns-records-update",
        action="store_true",
        help="Do not update UniFi DNS policies.",
    )
    parser.add_argument(
        "--static-routes-json",
        default=os.environ.get("UNIFI_STATIC_ROUTES_JSON", ""),
        help=(
            "Optional JSON array of static routes to upsert through the legacy UniFi "
            "routing API. Defaults to UNIFI_STATIC_ROUTES_JSON."
        ),
    )
    parser.add_argument(
        "--no-static-routes-update",
        action="store_true",
        help="Do not update UniFi static routes.",
    )
    return parser
