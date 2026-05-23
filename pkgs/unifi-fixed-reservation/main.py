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
        prog="unifi-fixed-reservation",
        description=(
            "Set UniFi fixed reservations through the legacy UniFi OS API, either "
            "for one client or for every MAC-backed reservation exported from inventory."
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

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
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


def build_update_payload(
    network_id: str,
    fixed_ip: ipaddress.IPv4Address,
    local_dns_record: str | None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "use_fixedip": True,
        "network_id": network_id,
        "fixed_ip": str(fixed_ip),
    }
    if local_dns_record is not None:
        payload["local_dns_record_enabled"] = True
        payload["local_dns_record"] = local_dns_record
    return payload


def build_network_dhcp_payload(dhcp_range: DhcpRangeSpec) -> dict[str, Any]:
    return {
        "dhcpd_enabled": True,
        "dhcpd_start": str(dhcp_range.start),
        "dhcpd_stop": str(dhcp_range.end),
    }


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        mode, reservations = load_reservations(args)
        dhcp_range = None if args.no_dhcp_range_update else parse_dhcp_range(args.dhcp_range_json)

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

        if dhcp_range is not None:
            selected_dhcp_network = (
                next((network for network in networks if network.get("_id") == args.network_id), None)
                if args.network_id
                else choose_network_by_ip(networks, dhcp_range.start)
            )
            if selected_dhcp_network is None:
                raise UnifiError(f"network not found: {args.network_id}")

            dhcp_network_id = _id(selected_dhcp_network)
            if dhcp_network_id == "<missing-id>":
                raise UnifiError("selected DHCP network has no _id")

            dhcp_result = client.update_network(
                network_id=dhcp_network_id,
                payload=build_network_dhcp_payload(dhcp_range),
            )
            dhcp_range_result = {
                "network_id": dhcp_network_id,
                "network_name": selected_dhcp_network.get("name"),
                "start": str(dhcp_range.start),
                "end": str(dhcp_range.end),
                "result": dhcp_result,
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
                if selected_group is None:
                    groups = client.list_usergroups()
                    selected_group = choose_usergroup(groups, args.usergroup_id)
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

            result = client.update_client(
                client_id=client_id,
                payload=build_update_payload(
                    network_id=network_id,
                    fixed_ip=reservation.fixed_ip,
                    local_dns_record=local_dns_record,
                ),
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
                    "local_dns_record": local_dns_record,
                    "result": result,
                }
            )

        summary = {
            "site": args.site,
            "mode": mode,
            "count": len(results),
            "dhcp_range_update": dhcp_range_result,
            "results": results,
        }
        print(format_json(summary))
        return 0
    except UnifiError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
