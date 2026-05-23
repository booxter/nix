#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.cookiejar import CookieJar
from typing import Any


MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
DEFAULT_GROUP_NAMES = {"default"}
SUPPORTED_DNS_RECORD_TYPES = {"A_RECORD", "CNAME_RECORD"}


class UnifiError(RuntimeError):
    pass


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
    tftp_server: str | None
    bootfile: str | None


@dataclass(frozen=True)
class DnsRecordSpec:
    record_type: str
    domain: str
    ttl_seconds: int
    ipv4_address: ipaddress.IPv4Address | None = None
    target_domain: str | None = None


@dataclass(frozen=True)
class DhcpCustomOptionSpec:
    code: int | None
    name: str | None
    option_type: str | None
    signed: bool | None
    encoding: str
    field_name: str | None = None


def normalize_mac(mac: str) -> str:
    cleaned = re.sub(r"[^0-9a-fA-F]", "", mac)
    if len(cleaned) != 12:
        raise UnifiError(f"invalid MAC address: {mac}")

    normalized = ":".join(cleaned[i : i + 2] for i in range(0, 12, 2)).lower()
    if not MAC_RE.match(normalized):
        raise UnifiError(f"invalid MAC address: {mac}")
    return normalized


def format_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


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
        "--strict-tls",
        action="store_true",
        help="Verify the UniFi TLS certificate. Defaults to disabled for local self-signed consoles.",
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
            '{"code":119,"name":"DomainSearch","type":"text","signed":false,"encoding":"hex"}. '
            "Defaults to UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_JSON."
        ),
    )
    parser.add_argument(
        "--domain-search-option-field",
        default=os.environ.get("UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_FIELD", ""),
        help=(
            "Optional generated UniFi networkconf field name for the custom DHCP option slot "
            "used to carry the domain-search list, for example dhcpd_user_option_<id>. "
            "Defaults to UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_FIELD."
        ),
    )
    parser.add_argument(
        "--domain-search-option-encoding",
        default=os.environ.get("UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_ENCODING", ""),
        help=(
            "Encoding to use when writing the custom DHCP option slot named by "
            "--domain-search-option-field. Supported values: hex, latin1. Defaults to "
            "UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_ENCODING or hex."
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
    return parser


class UnifiLegacyClient:
    def __init__(self, base_url: str, api_key: str, site: str, verify_tls: bool, debug: bool):
        if not base_url:
            raise UnifiError("missing UniFi base URL; pass --base-url or set UNIFI_BASE_URL")
        if not api_key:
            raise UnifiError("missing UniFi API key; pass --api-key or set UNIFI_API_KEY")

        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.site = site
        self.debug = debug
        self.cookie_jar: CookieJar = CookieJar()

        if verify_tls:
            context = ssl.create_default_context()
        else:
            context = ssl._create_unverified_context()

        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            urllib.request.HTTPCookieProcessor(self.cookie_jar),
        )

    def _url(self, path: str) -> str:
        return f"{self.base_url}/proxy/network{path}"

    def _csrf_header(self) -> dict[str, str]:
        for cookie in self.cookie_jar:
            if cookie.name != "TOKEN":
                continue

            parts = cookie.value.split(".")
            if len(parts) < 2:
                continue

            payload = parts[1]
            payload += "=" * (-len(payload) % 4)
            try:
                decoded = base64.urlsafe_b64decode(payload.encode("ascii"))
                token = json.loads(decoded.decode("utf-8"))["csrfToken"]
            except (KeyError, ValueError, json.JSONDecodeError):
                continue
            return {"x-csrf-token": token}

        return {}

    def request_json(self, method: str, path: str, payload: Any | None = None) -> Any:
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-API-Key": self.api_key,
        }

        data = None
        if payload is not None:
            headers.update(self._csrf_header())
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")

        url = self._url(path)
        if self.debug:
            print(f"[debug] {method} {url}", file=sys.stderr)
            if payload is not None:
                print(f"[debug] payload={format_json(payload)}", file=sys.stderr)

        request = urllib.request.Request(url, method=method, headers=headers, data=data)
        try:
            with self.opener.open(request) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            raise UnifiError(
                f"{method} {url} failed with HTTP {error.code}\n{body}"
            ) from error
        except urllib.error.URLError as error:
            raise UnifiError(f"{method} {url} failed: {error.reason}") from error

        if self.debug and body:
            print(f"[debug] response={body}", file=sys.stderr)

        if not body:
            return None

        try:
            decoded = json.loads(body)
        except json.JSONDecodeError as error:
            raise UnifiError(f"{method} {url} returned invalid JSON:\n{body}") from error

        meta = decoded.get("meta")
        if isinstance(meta, dict) and meta.get("rc") not in (None, "ok"):
            raise UnifiError(f"{method} {url} returned rc={meta.get('rc')}:\n{body}")

        return decoded

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
        decoded = self.request_json(method, path, payload)
        return decoded.get("data", decoded)

    def list_known_clients(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/list/user")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for known clients")
        return data

    def list_usergroups(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/list/usergroup")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for user groups")
        return data

    def list_networks(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/rest/networkconf")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for networks")
        return data

    def list_dhcp_options(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/rest/dhcpoption")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for DHCP options")
        return data

    def create_dhcp_option(self, payload: dict[str, Any]) -> dict[str, Any]:
        data = self.request("POST", f"/api/s/{self.site}/rest/dhcpoption", payload)
        if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
            raise UnifiError("unexpected response shape when creating DHCP option")
        return data[0]

    def create_known_client(
        self,
        mac: str,
        usergroup_id: str,
        client_name: str | None,
    ) -> Any:
        client_data: dict[str, Any] = {
            "mac": mac,
            "usergroup_id": usergroup_id,
            "is_wired": True,
        }
        if client_name:
            client_data["name"] = client_name

        return self.request(
            "POST",
            f"/api/s/{self.site}/group/user",
            {"objects": [{"data": client_data}]},
        )

    def update_client(self, client_id: str, payload: dict[str, Any]) -> Any:
        return self.request(
            "PUT",
            f"/api/s/{self.site}/rest/user/{urllib.parse.quote(client_id, safe='')}",
            {"_id": client_id, **payload},
        )

    def update_network(self, network_id: str, payload: dict[str, Any]) -> Any:
        return self.request(
            "PUT",
            f"/api/s/{self.site}/rest/networkconf/{urllib.parse.quote(network_id, safe='')}",
            {"_id": network_id, **payload},
        )

    def list_sites(self) -> list[dict[str, Any]]:
        return self._list_paginated("/integration/v1/sites")

    def list_dns_policies(self, site_id: str) -> list[dict[str, Any]]:
        return self._list_paginated(
            f"/integration/v1/sites/{urllib.parse.quote(site_id, safe='')}/dns/policies"
        )

    def create_dns_policy(self, site_id: str, payload: dict[str, Any]) -> Any:
        return self.request_json(
            "POST",
            f"/integration/v1/sites/{urllib.parse.quote(site_id, safe='')}/dns/policies",
            payload,
        )

    def update_dns_policy(self, site_id: str, policy_id: str, payload: dict[str, Any]) -> Any:
        return self.request_json(
            "PUT",
            (
                f"/integration/v1/sites/{urllib.parse.quote(site_id, safe='')}/dns/policies/"
                f"{urllib.parse.quote(policy_id, safe='')}"
            ),
            payload,
        )

    def _list_paginated(self, path: str, limit: int = 200) -> list[dict[str, Any]]:
        offset = 0
        items: list[dict[str, Any]] = []

        while True:
            separator = "&" if "?" in path else "?"
            page = self.request_json(
                "GET",
                f"{path}{separator}offset={offset}&limit={limit}",
            )
            if not isinstance(page, dict):
                raise UnifiError(f"unexpected paginated response shape for {path}")

            data = page.get("data")
            if not isinstance(data, list):
                raise UnifiError(f"unexpected paginated data shape for {path}")

            items.extend(item for item in data if isinstance(item, dict))

            count = page.get("count")
            total_count = page.get("totalCount")
            if not isinstance(count, int) or count <= 0:
                break
            if isinstance(total_count, int) and offset + count >= total_count:
                break

            offset += count

        return items


def _id(item: dict[str, Any]) -> str:
    value = item.get("_id")
    return str(value) if value is not None else "<missing-id>"


def choose_network_by_ip(networks: list[dict[str, Any]], fixed_ip: ipaddress.IPv4Address) -> dict[str, Any]:
    matches: list[tuple[int, dict[str, Any]]] = []
    for network in networks:
        subnet = network.get("ip_subnet")
        if not subnet:
            continue

        try:
            parsed = ipaddress.ip_network(subnet, strict=False)
        except ValueError:
            continue

        if fixed_ip in parsed:
            matches.append((parsed.prefixlen, network))

    if not matches:
        raise UnifiError(f"no UniFi networkconf contains IP {fixed_ip}")

    matches.sort(key=lambda item: item[0], reverse=True)
    best_prefix = matches[0][0]
    best = [network for prefixlen, network in matches if prefixlen == best_prefix]

    if len(best) > 1:
        choices = ", ".join(
            f"{network.get('name', '<unnamed>')}({_id(network)})" for network in best
        )
        raise UnifiError(
            f"multiple networkconf entries match {fixed_ip} with the same prefix length: {choices}"
        )

    return best[0]


def find_client_by_mac(clients: list[dict[str, Any]], mac: str) -> dict[str, Any] | None:
    for client in clients:
        candidate = client.get("mac")
        if isinstance(candidate, str) and candidate.lower() == mac:
            return client
    return None


def build_clients_by_mac(clients: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    by_mac: dict[str, dict[str, Any]] = {}
    for client in clients:
        candidate = client.get("mac")
        if not isinstance(candidate, str):
            continue
        try:
            normalized = normalize_mac(candidate)
        except UnifiError:
            continue
        by_mac[normalized] = client
    return by_mac


def choose_usergroup(groups: list[dict[str, Any]], explicit_id: str) -> dict[str, Any]:
    if explicit_id:
        for group in groups:
            if group.get("_id") == explicit_id:
                return group
        raise UnifiError(f"user group not found: {explicit_id}")

    if len(groups) == 1:
        return groups[0]

    default_matches = [
        group
        for group in groups
        if isinstance(group.get("name"), str) and group["name"].strip().lower() in DEFAULT_GROUP_NAMES
    ]
    if len(default_matches) == 1:
        return default_matches[0]

    choices = ", ".join(
        f"{group.get('name', '<unnamed>')}({_id(group)})" for group in groups
    )
    raise UnifiError(
        "cannot choose a user group automatically; pass --usergroup-id. "
        f"Available groups: {choices}"
    )


def parse_inventory_reservations(raw_json: str) -> list[ReservationSpec]:
    if not raw_json:
        raise UnifiError(
            "missing inventory reservations; pass --inventory-json or run through the flake app wrapper"
        )

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid inventory JSON: {error}") from error

    if not isinstance(decoded, list):
        raise UnifiError("inventory JSON must be a list of reservation objects")

    reservations: list[ReservationSpec] = []
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise UnifiError(f"inventory item {index} is not an object")

        hostname = item.get("hostname")
        mac = item.get("mac")
        fixed_ip = item.get("ip")

        if not isinstance(hostname, str) or not hostname.strip():
            raise UnifiError(f"inventory item {index} is missing hostname")
        if not isinstance(mac, str):
            raise UnifiError(f"inventory item {index} is missing mac")
        if not isinstance(fixed_ip, str):
            raise UnifiError(f"inventory item {index} is missing ip")

        parsed_ip = ipaddress.ip_address(fixed_ip)
        if not isinstance(parsed_ip, ipaddress.IPv4Address):
            raise UnifiError(f"inventory item {index} uses non-IPv4 address: {fixed_ip}")

        reservations.append(
            ReservationSpec(
                hostname=hostname.strip(),
                mac=normalize_mac(mac),
                fixed_ip=parsed_ip,
            )
        )

    return reservations


def parse_dhcp_range(raw_json: str) -> DhcpRangeSpec | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid DHCP range JSON: {error}") from error

    if not isinstance(decoded, dict):
        raise UnifiError("DHCP range JSON must be an object")

    start = decoded.get("start")
    end = decoded.get("end")
    if not isinstance(start, str) or not isinstance(end, str):
        raise UnifiError("DHCP range JSON must contain string start and end fields")

    start_ip = ipaddress.ip_address(start)
    end_ip = ipaddress.ip_address(end)
    if not isinstance(start_ip, ipaddress.IPv4Address) or not isinstance(end_ip, ipaddress.IPv4Address):
        raise UnifiError("only IPv4 DHCP ranges are supported by this tool")
    if start_ip > end_ip:
        raise UnifiError(f"invalid DHCP range: {start_ip} is after {end_ip}")

    return DhcpRangeSpec(start=start_ip, end=end_ip)


def parse_domain_search(raw_json: str) -> tuple[str, ...] | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError:
        decoded = raw_json

    if isinstance(decoded, str):
        values = [decoded]
    elif isinstance(decoded, list):
        values = decoded
    else:
        raise UnifiError("domain-search must be a JSON string or array of strings")

    parsed: list[str] = []
    for index, item in enumerate(values):
        if not isinstance(item, str):
            raise UnifiError(f"domain-search item {index} is not a string")

        domain = item.strip().rstrip(".")
        if not domain:
            raise UnifiError(f"domain-search item {index} is empty")

        labels = domain.split(".")
        for label in labels:
            if not label:
                raise UnifiError(f"domain-search item {index} has an empty label: {domain}")
            if len(label.encode("idna")) > 63:
                raise UnifiError(f"domain-search label is too long in {domain}")

        encoded_length = sum(len(label.encode("idna")) + 1 for label in labels) + 1
        if encoded_length > 255:
            raise UnifiError(f"domain-search item {index} is too long: {domain}")

        parsed.append(domain.lower())

    if not parsed:
        return None

    return tuple(parsed)


def normalize_dns_name(value: str) -> str:
    normalized = value.strip().rstrip(".").lower()
    if not normalized:
        raise UnifiError("DNS name must not be empty")

    labels = normalized.split(".")
    for label in labels:
        if not label:
            raise UnifiError(f"DNS name has an empty label: {value}")
        if len(label.encode("idna")) > 63:
            raise UnifiError(f"DNS label is too long in {value}")

    encoded_length = sum(len(label.encode("idna")) + 1 for label in labels) + 1
    if encoded_length > 255:
        raise UnifiError(f"DNS name is too long: {value}")

    return normalized


def normalize_tftp_server(value: str) -> str:
    normalized = value.strip().rstrip(".")
    if not normalized:
        raise UnifiError("TFTP server must not be empty")

    try:
        parsed_ip = ipaddress.ip_address(normalized)
    except ValueError:
        return normalize_dns_name(normalized)

    if not isinstance(parsed_ip, ipaddress.IPv4Address):
        raise UnifiError(f"TFTP server must be an IPv4 address or hostname: {value}")
    return str(parsed_ip)


def normalize_bootfile(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        raise UnifiError("bootfile must not be empty")
    if any(ord(character) < 32 for character in normalized):
        raise UnifiError("bootfile must not contain control characters")
    if len(normalized.encode("utf-8")) > 256:
        raise UnifiError("bootfile is too long")
    return normalized


def normalize_networkconf_field_name(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        raise UnifiError("networkconf field name must not be empty")
    if not re.fullmatch(r"[A-Za-z0-9_]+", normalized):
        raise UnifiError(f"invalid networkconf field name: {value}")
    return normalized


def normalize_domain_search_option_encoding(value: str) -> str:
    normalized = value.strip().lower()
    if not normalized:
        return "hex"

    aliases = {
        "hex": "hex",
        "hexadecimal": "hex",
        "latin1": "latin1",
        "raw": "latin1",
    }
    if normalized not in aliases:
        raise UnifiError(
            "domain-search option encoding must be one of: hex, hexadecimal, latin1, raw"
        )
    return aliases[normalized]


def normalize_dhcp_option_name(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        raise UnifiError("DHCP option name must not be empty")
    if not re.fullmatch(r"[A-Za-z0-9]+", normalized):
        raise UnifiError(
            f"DHCP option name must contain only letters and numbers: {value}"
        )
    return normalized


def normalize_dhcp_option_type(value: str) -> str:
    normalized = value.strip().lower()
    if not normalized:
        raise UnifiError("DHCP option type must not be empty")
    if not re.fullmatch(r"[a-z]+", normalized):
        raise UnifiError(f"invalid DHCP option type: {value}")
    return normalized


def normalize_dhcp_option_code(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise UnifiError(f"DHCP option code must be an integer, got: {value!r}")
    if value < 1 or value > 254:
        raise UnifiError(f"DHCP option code must be between 1 and 254, got: {value}")
    return value


def parse_domain_search_option_json(raw_json: str) -> DhcpCustomOptionSpec | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid domain-search option JSON: {error}") from error

    if not isinstance(decoded, dict):
        raise UnifiError("domain-search option JSON must be an object")

    code = normalize_dhcp_option_code(decoded.get("code"))
    name = normalize_dhcp_option_name(str(decoded.get("name", "")))
    option_type = normalize_dhcp_option_type(str(decoded.get("type", "")))
    signed = decoded.get("signed")
    if not isinstance(signed, bool):
        raise UnifiError("domain-search option JSON must contain boolean signed")

    encoding = normalize_domain_search_option_encoding(str(decoded.get("encoding", "")))
    return DhcpCustomOptionSpec(
        code=code,
        name=name,
        option_type=option_type,
        signed=signed,
        encoding=encoding,
        field_name=None,
    )


def parse_dns_records(raw_json: str) -> list[DnsRecordSpec] | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid DNS records JSON: {error}") from error

    if not isinstance(decoded, list):
        raise UnifiError("DNS records JSON must be a list")

    records: list[DnsRecordSpec] = []
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise UnifiError(f"DNS record item {index} is not an object")

        record_type = item.get("type")
        domain = item.get("domain")
        ttl_seconds = item.get("ttlSeconds")
        if not isinstance(record_type, str):
            raise UnifiError(f"DNS record item {index} is missing type")
        if not isinstance(domain, str):
            raise UnifiError(f"DNS record item {index} is missing domain")
        if not isinstance(ttl_seconds, int) or ttl_seconds < 0:
            raise UnifiError(f"DNS record item {index} is missing non-negative integer ttlSeconds")

        normalized_type = record_type.strip().upper()
        if normalized_type not in SUPPORTED_DNS_RECORD_TYPES:
            supported = ", ".join(sorted(SUPPORTED_DNS_RECORD_TYPES))
            raise UnifiError(
                f"DNS record item {index} uses unsupported type {record_type!r}; supported: {supported}"
            )

        normalized_domain = normalize_dns_name(domain)
        if normalized_type == "A_RECORD":
            ipv4_address = item.get("ipv4Address")
            if not isinstance(ipv4_address, str):
                raise UnifiError(f"DNS A record item {index} is missing ipv4Address")
            parsed_ip = ipaddress.ip_address(ipv4_address)
            if not isinstance(parsed_ip, ipaddress.IPv4Address):
                raise UnifiError(f"DNS A record item {index} is not IPv4: {ipv4_address}")
            records.append(
                DnsRecordSpec(
                    record_type=normalized_type,
                    domain=normalized_domain,
                    ttl_seconds=ttl_seconds,
                    ipv4_address=parsed_ip,
                )
            )
            continue

        target_domain = item.get("targetDomain")
        if not isinstance(target_domain, str):
            raise UnifiError(f"DNS CNAME record item {index} is missing targetDomain")
        records.append(
            DnsRecordSpec(
                record_type=normalized_type,
                domain=normalized_domain,
                ttl_seconds=ttl_seconds,
                target_domain=normalize_dns_name(target_domain),
            )
        )

    return records


def encode_domain_search_option(domains: tuple[str, ...]) -> str:
    encoded = bytearray()
    for domain in domains:
        for label in domain.split("."):
            label_bytes = label.encode("idna")
            encoded.append(len(label_bytes))
            encoded.extend(label_bytes)
        encoded.append(0)
    return bytes(encoded).decode("latin1")


def build_single_reservation(args: argparse.Namespace) -> ReservationSpec:
    if not args.mac and not args.ip and not args.hostname:
        raise UnifiError("single-client mode requires at least --mac and --ip")
    if not args.mac or not args.ip:
        raise UnifiError("single-client mode requires both --mac and --ip")

    fixed_ip = ipaddress.ip_address(args.ip)
    if not isinstance(fixed_ip, ipaddress.IPv4Address):
        raise UnifiError("only IPv4 fixed reservations are supported by this tool")

    hostname = args.hostname.strip() or None
    return ReservationSpec(
        hostname=hostname,
        mac=normalize_mac(args.mac),
        fixed_ip=fixed_ip,
    )


def load_reservations(args: argparse.Namespace) -> tuple[str, list[ReservationSpec]]:
    if args.mac or args.ip or args.hostname:
        return "single", [build_single_reservation(args)]
    return "inventory", parse_inventory_reservations(args.inventory_json)


def build_network_dhcp_payload(dhcp_range: DhcpRangeSpec) -> dict[str, Any]:
    return {
        "dhcpd_enabled": True,
        "dhcpd_start": str(dhcp_range.start),
        "dhcpd_stop": str(dhcp_range.end),
    }


def build_network_settings(
    args: argparse.Namespace,
) -> NetworkDhcpSettingsSpec | None:
    dhcp_range = None if args.no_dhcp_range_update else parse_dhcp_range(args.dhcp_range_json)
    domain_name = args.domain_name.strip() or None
    domain_search = parse_domain_search(args.domain_search_json)
    direct_field_name = (
        normalize_networkconf_field_name(args.domain_search_option_field)
        if args.domain_search_option_field.strip()
        else None
    )
    json_option_spec = parse_domain_search_option_json(args.domain_search_option_json)
    if direct_field_name is not None and json_option_spec is not None:
        raise UnifiError(
            "use either --domain-search-option-json or --domain-search-option-field, not both"
        )
    if direct_field_name is not None:
        domain_search_option = DhcpCustomOptionSpec(
            code=None,
            name=None,
            option_type=None,
            signed=None,
            encoding=normalize_domain_search_option_encoding(args.domain_search_option_encoding),
            field_name=direct_field_name,
        )
    else:
        domain_search_option = json_option_spec
    raw_tftp_server = None if args.no_netboot_update else (args.tftp_server.strip() or None)
    raw_bootfile = None if args.no_netboot_update else (args.bootfile.strip() or None)
    if (raw_tftp_server is None) != (raw_bootfile is None):
        raise UnifiError("network boot requires both --tftp-server and --bootfile together")
    tftp_server = normalize_tftp_server(raw_tftp_server) if raw_tftp_server is not None else None
    bootfile = normalize_bootfile(raw_bootfile) if raw_bootfile is not None else None
    if domain_search is not None and domain_search_option is None:
        domain_search = None

    if dhcp_range is None and domain_name is None and domain_search is None and tftp_server is None:
        return None

    return NetworkDhcpSettingsSpec(
        dhcp_range=dhcp_range,
        domain_name=domain_name,
        domain_search=domain_search,
        domain_search_option=domain_search_option,
        tftp_server=tftp_server,
        bootfile=bootfile,
    )


def stringify(value: Any) -> str | None:
    return None if value is None else str(value)


def build_change(current: Any, desired: Any) -> dict[str, Any]:
    return {
        "current": current,
        "desired": desired,
    }


def choose_site(sites: list[dict[str, Any]], requested_site: str) -> dict[str, Any]:
    matches = [
        site
        for site in sites
        if requested_site
        and requested_site
        in {
            stringify(site.get("id")),
            stringify(site.get("internalReference")),
            stringify(site.get("name")),
        }
    ]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        choices = ", ".join(
            f"{site.get('name', '<unnamed>')}[{site.get('internalReference', '?')}:{site.get('id', '?')}]"
            for site in matches
        )
        raise UnifiError(f"multiple UniFi sites match {requested_site!r}: {choices}")

    if len(sites) == 1:
        return sites[0]

    choices = ", ".join(
        f"{site.get('name', '<unnamed>')}[{site.get('internalReference', '?')}:{site.get('id', '?')}]"
        for site in sites
    )
    raise UnifiError(
        f"could not match UniFi site {requested_site!r} in official API site list. Available: {choices}"
    )


def dns_policy_key(record_type: str, domain: str) -> tuple[str, str]:
    return record_type.upper(), normalize_dns_name(domain)


def build_dns_policies_by_key(policies: list[dict[str, Any]]) -> dict[tuple[str, str], dict[str, Any]]:
    by_key: dict[tuple[str, str], dict[str, Any]] = {}
    for policy in policies:
        record_type = policy.get("type")
        domain = policy.get("domain")
        if not isinstance(record_type, str) or not isinstance(domain, str):
            continue

        key = dns_policy_key(record_type, domain)
        if key in by_key:
            raise UnifiError(
                f"multiple UniFi DNS policies share the same key {record_type}:{domain}"
            )
        by_key[key] = policy
    return by_key


def build_dns_policy_payload(record: DnsRecordSpec) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "enabled": True,
        "type": record.record_type,
        "domain": record.domain,
        "ttlSeconds": record.ttl_seconds,
    }
    if record.record_type == "A_RECORD":
        payload["ipv4Address"] = str(record.ipv4_address)
    elif record.record_type == "CNAME_RECORD":
        payload["targetDomain"] = record.target_domain
    else:
        raise UnifiError(f"unsupported DNS record type: {record.record_type}")
    return payload


def build_dns_policy_update_plan(
    existing_policy: dict[str, Any] | None,
    record: DnsRecordSpec,
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    desired_payload = build_dns_policy_payload(record)
    changes: dict[str, Any] = {}

    if existing_policy is None:
        for key, value in desired_payload.items():
            changes[key] = build_change(None, value)
        return "create", desired_payload, changes

    payload: dict[str, Any] = {}
    current_enabled = bool(existing_policy.get("enabled"))
    if not current_enabled:
        payload["enabled"] = True
        changes["enabled"] = build_change(current_enabled, True)

    current_domain = stringify(existing_policy.get("domain"))
    if current_domain != record.domain:
        changes["domain"] = build_change(current_domain, record.domain)

    current_ttl_seconds = existing_policy.get("ttlSeconds")
    if current_ttl_seconds != record.ttl_seconds:
        changes["ttlSeconds"] = build_change(current_ttl_seconds, record.ttl_seconds)

    if record.record_type == "A_RECORD":
        desired_ipv4 = str(record.ipv4_address)
        current_ipv4 = stringify(existing_policy.get("ipv4Address"))
        if current_ipv4 != desired_ipv4:
            changes["ipv4Address"] = build_change(current_ipv4, desired_ipv4)
    elif record.record_type == "CNAME_RECORD":
        current_target = stringify(existing_policy.get("targetDomain"))
        desired_target = record.target_domain
        if current_target != desired_target:
            changes["targetDomain"] = build_change(current_target, desired_target)
    else:
        raise UnifiError(f"unsupported DNS record type: {record.record_type}")

    if changes:
        return "update", desired_payload, changes
    return "noop", {}, changes


def build_client_update_plan(
    existing_client: dict[str, Any],
    network_id: str,
    fixed_ip: ipaddress.IPv4Address,
    local_dns_record: str | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    payload: dict[str, Any] = {}
    changes: dict[str, Any] = {}

    desired_fixed_ip = str(fixed_ip)
    current_use_fixedip = bool(existing_client.get("use_fixedip"))
    current_network_id = stringify(existing_client.get("network_id"))
    current_fixed_ip = stringify(existing_client.get("fixed_ip"))

    if not current_use_fixedip:
        payload["use_fixedip"] = True
        changes["use_fixedip"] = build_change(current_use_fixedip, True)
    if current_network_id != network_id:
        payload["network_id"] = network_id
        changes["network_id"] = build_change(current_network_id, network_id)
    if current_fixed_ip != desired_fixed_ip:
        payload["fixed_ip"] = desired_fixed_ip
        changes["fixed_ip"] = build_change(current_fixed_ip, desired_fixed_ip)

    if local_dns_record is not None:
        current_local_dns_enabled = bool(existing_client.get("local_dns_record_enabled"))
        current_local_dns_record = stringify(existing_client.get("local_dns_record"))
        if not current_local_dns_enabled:
            payload["local_dns_record_enabled"] = True
            changes["local_dns_record_enabled"] = build_change(current_local_dns_enabled, True)
        if current_local_dns_record != local_dns_record:
            payload["local_dns_record"] = local_dns_record
            changes["local_dns_record"] = build_change(current_local_dns_record, local_dns_record)

    return payload, changes


def dhcp_option_field_name(option_id: str) -> str:
    return f"dhcpd_user_option_{option_id}"


def build_dhcp_options_by_code(
    options: list[dict[str, Any]],
) -> dict[int, list[dict[str, Any]]]:
    by_code: dict[int, list[dict[str, Any]]] = {}
    for option in options:
        code = option.get("code")
        if isinstance(code, bool) or not isinstance(code, int):
            continue
        by_code.setdefault(code, []).append(option)
    return by_code


def choose_existing_dhcp_option(
    options_by_code: dict[int, list[dict[str, Any]]],
    desired: DhcpCustomOptionSpec,
) -> dict[str, Any] | None:
    if desired.code is None:
        return None

    candidates = options_by_code.get(desired.code, [])
    if not candidates:
        return None

    exact_matches = [
        option
        for option in candidates
        if stringify(option.get("name")) == desired.name
        and stringify(option.get("type")) == desired.option_type
        and option.get("signed") == desired.signed
    ]
    if len(exact_matches) == 1:
        return exact_matches[0]
    if len(exact_matches) > 1:
        raise UnifiError(
            f"multiple UniFi DHCP option definitions match code {desired.code} and name {desired.name}"
        )

    if len(candidates) == 1:
        return candidates[0]

    choices = ", ".join(
        f"{option.get('name', '<unnamed>')}({_id(option)} type={option.get('type')} signed={option.get('signed')})"
        for option in candidates
    )
    raise UnifiError(
        f"multiple UniFi DHCP option definitions share code {desired.code}; refine the desired definition. "
        f"Available: {choices}"
    )


def ensure_domain_search_option(
    client: UnifiLegacyClient,
    desired: DhcpCustomOptionSpec,
    dry_run: bool,
) -> tuple[str | None, dict[str, Any]]:
    if desired.field_name is not None:
        return (
            desired.field_name,
            {
                "field_name": desired.field_name,
                "code": desired.code,
                "name": desired.name,
                "type": desired.option_type,
                "signed": desired.signed,
                "encoding": desired.encoding,
                "changed": False,
                "dry_run": dry_run,
                "created": False,
                "result": None,
            },
        )

    options = client.list_dhcp_options()
    options_by_code = build_dhcp_options_by_code(options)
    existing = choose_existing_dhcp_option(options_by_code, desired)
    if existing is not None:
        option_id = _id(existing)
        if option_id == "<missing-id>":
            raise UnifiError(
                f"existing UniFi DHCP option definition for code {desired.code} has no _id"
            )
        return (
            dhcp_option_field_name(option_id),
            {
                "field_name": dhcp_option_field_name(option_id),
                "code": desired.code,
                "name": desired.name,
                "type": desired.option_type,
                "signed": desired.signed,
                "encoding": desired.encoding,
                "changed": False,
                "dry_run": dry_run,
                "created": False,
                "option_id": option_id,
                "result": None,
            },
        )

    if dry_run:
        return (
            None,
            {
                "field_name": None,
                "code": desired.code,
                "name": desired.name,
                "type": desired.option_type,
                "signed": desired.signed,
                "encoding": desired.encoding,
                "changed": True,
                "dry_run": True,
                "created": False,
                "would_create": True,
                "result": None,
            },
        )

    created = client.create_dhcp_option(
        {
            "code": desired.code,
            "name": desired.name,
            "type": desired.option_type,
            "signed": desired.signed,
        }
    )
    option_id = _id(created)
    if option_id == "<missing-id>":
        raise UnifiError(
            f"created UniFi DHCP option definition for code {desired.code} has no _id"
        )
    return (
        dhcp_option_field_name(option_id),
        {
            "field_name": dhcp_option_field_name(option_id),
            "code": desired.code,
            "name": desired.name,
            "type": desired.option_type,
            "signed": desired.signed,
            "encoding": desired.encoding,
            "changed": True,
            "dry_run": False,
            "created": True,
            "would_create": False,
            "option_id": option_id,
            "result": created,
        },
    )


def build_network_update_payload(
    settings: NetworkDhcpSettingsSpec,
    current_network: dict[str, Any],
    domain_search_option_field: str | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    payload: dict[str, Any] = {}
    changes: dict[str, Any] = {}

    if settings.dhcp_range is not None:
        desired_start = str(settings.dhcp_range.start)
        desired_stop = str(settings.dhcp_range.end)
        current_enabled = bool(current_network.get("dhcpd_enabled"))
        current_start = stringify(current_network.get("dhcpd_start"))
        current_stop = stringify(current_network.get("dhcpd_stop"))

        if not current_enabled or current_start != desired_start or current_stop != desired_stop:
            payload.update(build_network_dhcp_payload(settings.dhcp_range))
        if not current_enabled:
            changes["dhcpd_enabled"] = build_change(current_enabled, True)
        if current_start != desired_start:
            changes["dhcpd_start"] = build_change(current_start, desired_start)
        if current_stop != desired_stop:
            changes["dhcpd_stop"] = build_change(current_stop, desired_stop)

    if settings.domain_name is not None:
        current_domain_name = stringify(current_network.get("domain_name"))
        if current_domain_name != settings.domain_name:
            payload["domain_name"] = settings.domain_name
            changes["domain_name"] = build_change(current_domain_name, settings.domain_name)

    if settings.domain_search is not None:
        desired_option_value = encode_domain_search_option(settings.domain_search)
        if domain_search_option_field is not None:
            current_option_value = stringify(current_network.get(domain_search_option_field))
            if settings.domain_search_option is None:
                raise UnifiError("internal error: domain_search present without option spec")

            if settings.domain_search_option.encoding == "hex":
                desired_networkconf_value = desired_option_value.encode("latin1").hex()
            elif settings.domain_search_option.encoding == "latin1":
                desired_networkconf_value = desired_option_value
            else:
                raise UnifiError(
                    f"unsupported domain-search option encoding: {settings.domain_search_option.encoding}"
                )

            if current_option_value != desired_networkconf_value:
                payload[domain_search_option_field] = desired_networkconf_value
                changes[domain_search_option_field] = {
                    "current": current_option_value,
                    "desired": desired_networkconf_value,
                    "desired_domains": list(settings.domain_search),
                    "encoding": settings.domain_search_option.encoding,
                }
    if settings.tftp_server is not None:
        current_boot_enabled = bool(current_network.get("dhcpd_boot_enabled"))
        current_boot_server = stringify(current_network.get("dhcpd_boot_server"))
        if not current_boot_enabled:
            payload["dhcpd_boot_enabled"] = True
            changes["dhcpd_boot_enabled"] = build_change(current_boot_enabled, True)
        if current_boot_server != settings.tftp_server:
            payload["dhcpd_boot_server"] = settings.tftp_server
            changes["dhcpd_boot_server"] = build_change(current_boot_server, settings.tftp_server)
    if settings.bootfile is not None:
        current_bootfile = stringify(current_network.get("dhcpd_boot_filename"))
        if current_bootfile != settings.bootfile:
            payload["dhcpd_boot_filename"] = settings.bootfile
            changes["dhcpd_boot_filename"] = build_change(current_bootfile, settings.bootfile)

    return payload, changes


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        mode, reservations = load_reservations(args)
        network_settings = build_network_settings(args)
        dns_records = None if args.no_dns_records_update else parse_dns_records(args.dns_records_json)

        client = UnifiLegacyClient(
            base_url=args.base_url,
            api_key=args.api_key,
            site=args.site,
            verify_tls=args.strict_tls,
            debug=args.debug,
        )

        networks = client.list_networks()
        clients = client.list_known_clients()
        clients_by_mac = build_clients_by_mac(clients)
        dhcp_range_result = None
        dns_records_result = None

        if network_settings is not None:
            lookup_ip = (
                network_settings.dhcp_range.start
                if network_settings.dhcp_range is not None
                else reservations[0].fixed_ip
            )
            selected_dhcp_network = (
                next((network for network in networks if network.get("_id") == args.network_id), None)
                if args.network_id
                else choose_network_by_ip(networks, lookup_ip)
            )
            if selected_dhcp_network is None:
                raise UnifiError(f"network not found: {args.network_id}")

            dhcp_network_id = _id(selected_dhcp_network)
            if dhcp_network_id == "<missing-id>":
                raise UnifiError("selected DHCP network has no _id")

            domain_search_option_field = None
            domain_search_option_result = None
            if network_settings.domain_search is not None:
                if network_settings.domain_search_option is None:
                    raise UnifiError(
                        "internal error: domain_search present without option specification"
                    )
                (
                    domain_search_option_field,
                    domain_search_option_result,
                ) = ensure_domain_search_option(
                    client=client,
                    desired=network_settings.domain_search_option,
                    dry_run=args.dry_run,
                )

            dhcp_payload, dhcp_changes = build_network_update_payload(
                network_settings,
                selected_dhcp_network,
                domain_search_option_field=domain_search_option_field,
            )
            dhcp_changed = bool(dhcp_payload) or bool(
                domain_search_option_result is not None and domain_search_option_result["changed"]
            )
            dhcp_result = None
            if dhcp_changed and not args.dry_run:
                dhcp_result = client.update_network(
                    network_id=dhcp_network_id,
                    payload=dhcp_payload,
                )
            dhcp_range_result = {
                "network_id": dhcp_network_id,
                "network_name": selected_dhcp_network.get("name"),
                "changed": dhcp_changed,
                "dry_run": args.dry_run,
                "changes": dhcp_changes,
                "start": (
                    str(network_settings.dhcp_range.start)
                    if network_settings.dhcp_range is not None
                    else None
                ),
                "end": (
                    str(network_settings.dhcp_range.end)
                    if network_settings.dhcp_range is not None
                    else None
                ),
                "domain_name": network_settings.domain_name,
                "domain_search": list(network_settings.domain_search)
                if network_settings.domain_search is not None
                else None,
                "domain_search_option": domain_search_option_result,
                "domain_search_option_119_hex": (
                    encode_domain_search_option(network_settings.domain_search)
                    .encode("latin1")
                    .hex()
                    if network_settings.domain_search is not None
                    else None
                ),
                "tftp_server": network_settings.tftp_server,
                "bootfile": network_settings.bootfile,
                "result": dhcp_result,
            }

        if dns_records is not None:
            if dns_records:
                official_sites = client.list_sites()
                selected_site = choose_site(official_sites, args.site)
                site_id = stringify(selected_site.get("id"))
                if not site_id:
                    raise UnifiError("selected official UniFi site has no id")

                existing_dns_policies = client.list_dns_policies(site_id)
                existing_dns_by_key = build_dns_policies_by_key(existing_dns_policies)

                dns_results: list[dict[str, Any]] = []
                for record in dns_records:
                    existing_policy = existing_dns_by_key.get(
                        dns_policy_key(record.record_type, record.domain)
                    )
                    action, payload, changes = build_dns_policy_update_plan(
                        existing_policy=existing_policy,
                        record=record,
                    )
                    changed = bool(payload)
                    result = None
                    if changed and not args.dry_run:
                        if existing_policy is None:
                            result = client.create_dns_policy(site_id, payload)
                        else:
                            policy_id = stringify(existing_policy.get("id"))
                            if not policy_id:
                                raise UnifiError(
                                    f"existing UniFi DNS policy for {record.domain} has no id"
                                )
                            result = client.update_dns_policy(site_id, policy_id, payload)

                    dns_results.append(
                        {
                            "type": record.record_type,
                            "domain": record.domain,
                            "policy_id": stringify(existing_policy.get("id"))
                            if existing_policy is not None
                            else None,
                            "action": action,
                            "changed": changed,
                            "dry_run": args.dry_run,
                            "changes": changes,
                            "result": result,
                        }
                    )
            else:
                selected_site = None
                site_id = None
                dns_results = []

            dns_records_result = {
                "site_id": site_id,
                "site_name": selected_site.get("name") if selected_site is not None else None,
                "site_internal_reference": (
                    selected_site.get("internalReference") if selected_site is not None else None
                ),
                "dry_run": args.dry_run,
                "count": len(dns_results),
                "changed_count": sum(1 for result in dns_results if result["changed"]),
                "results": dns_results,
            }

        selected_group: dict[str, Any] | None = None
        allow_inventory_placeholders = mode == "inventory" and not args.no_create_known_clients
        results: list[dict[str, Any]] = []

        for reservation in reservations:
            selected_network = (
                next((network for network in networks if network.get("_id") == args.network_id), None)
                if args.network_id
                else choose_network_by_ip(networks, reservation.fixed_ip)
            )
            if selected_network is None:
                raise UnifiError(f"network not found: {args.network_id}")

            network_id = _id(selected_network)
            if network_id == "<missing-id>":
                raise UnifiError("selected network has no _id")

            existing_client = clients_by_mac.get(reservation.mac)
            created_placeholder = False
            should_create_placeholder = args.create_known_client if mode == "single" else allow_inventory_placeholders
            if existing_client is None and should_create_placeholder:
                # TODO: Re-check on a live UCG whether placeholder-only known clients
                # behave identically to observed clients for fixed IP + Local DNS Record.
                if selected_group is None:
                    groups = client.list_usergroups()
                    selected_group = choose_usergroup(groups, args.usergroup_id)
                if not args.dry_run:
                    client.create_known_client(
                        mac=reservation.mac,
                        usergroup_id=_id(selected_group),
                        client_name=reservation.hostname or args.client_name,
                    )
                    created_placeholder = True
                    clients = client.list_known_clients()
                    clients_by_mac = build_clients_by_mac(clients)
                    existing_client = clients_by_mac.get(reservation.mac)

            if existing_client is None:
                if should_create_placeholder and args.dry_run:
                    payload, changes = build_client_update_plan(
                        existing_client={},
                        network_id=network_id,
                        fixed_ip=reservation.fixed_ip,
                        local_dns_record=(
                            reservation.hostname
                            if not args.no_local_dns_record and reservation.hostname is not None
                            else None
                        ),
                    )
                    results.append(
                        {
                            "hostname": reservation.hostname,
                            "mac": reservation.mac,
                            "fixed_ip": str(reservation.fixed_ip),
                            "client_id": None,
                            "network_id": network_id,
                            "network_name": selected_network.get("name"),
                            "created_placeholder": False,
                            "would_create_placeholder": True,
                            "changed": bool(payload),
                            "dry_run": True,
                            "changes": changes,
                            "local_dns_record": (
                                reservation.hostname
                                if not args.no_local_dns_record and reservation.hostname is not None
                                else None
                            ),
                            "result": None,
                        }
                    )
                    continue
                raise UnifiError(
                    f"known client not found for {reservation.mac}. "
                    "Retry with --create-known-client or without --no-create-known-clients."
                )

            client_id = _id(existing_client)
            if client_id == "<missing-id>":
                raise UnifiError(f"client record for {reservation.mac} has no _id")

            local_dns_record = None
            if not args.no_local_dns_record and reservation.hostname is not None:
                local_dns_record = reservation.hostname

            payload, changes = build_client_update_plan(
                existing_client=existing_client,
                network_id=network_id,
                fixed_ip=reservation.fixed_ip,
                local_dns_record=local_dns_record,
            )
            changed = bool(payload)
            result = None
            if changed and not args.dry_run:
                result = client.update_client(
                    client_id=client_id,
                    payload=payload,
                )

            results.append(
                {
                    "hostname": reservation.hostname,
                    "mac": reservation.mac,
                    "fixed_ip": str(reservation.fixed_ip),
                    "client_id": client_id,
                    "network_id": network_id,
                    "network_name": selected_network.get("name"),
                    "created_placeholder": created_placeholder,
                    "would_create_placeholder": False,
                    "changed": changed,
                    "dry_run": args.dry_run,
                    "changes": changes,
                    "local_dns_record": local_dns_record,
                    "result": result,
                }
            )

        summary = {
            "site": args.site,
            "mode": mode,
            "dry_run": args.dry_run,
            "count": len(results),
            "reservation_changed_count": sum(1 for result in results if result["changed"]),
            "changed_count": (
                sum(1 for result in results if result["changed"])
                + (1 if dhcp_range_result is not None and dhcp_range_result["changed"] else 0)
                + (
                    dns_records_result["changed_count"]
                    if dns_records_result is not None
                    else 0
                )
            ),
            "dhcp_range_update": dhcp_range_result,
            "dns_records_update": dns_records_result,
            "results": results,
        }
        print(format_json(summary))
        return 0
    except UnifiError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
