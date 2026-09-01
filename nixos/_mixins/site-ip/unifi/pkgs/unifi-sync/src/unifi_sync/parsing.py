from __future__ import annotations

import ipaddress
import json
import re
from collections.abc import Callable
from typing import Any

from .dns import normalize_dns_name
from .errors import UnifiError
from .models import (
    Arguments,
    ClasslessStaticRouteSpec,
    DhcpCustomOptionSpec,
    DhcpRangeSpec,
    ReservationSpec,
    StaticRouteSpec,
)

MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
DEFAULT_GROUP_NAMES = {"default"}


def normalize_mac(mac: str) -> str:
    cleaned = re.sub(r"[^0-9a-fA-F]", "", mac)
    if len(cleaned) != 12:
        raise UnifiError(f"invalid MAC address: {mac}")

    normalized = ":".join(cleaned[i : i + 2] for i in range(0, 12, 2)).lower()
    if not MAC_RE.match(normalized):
        raise UnifiError(f"invalid MAC address: {mac}")
    return normalized


def format_json(data: object) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def _id(item: dict[str, Any]) -> str:
    value = item.get("_id")
    return str(value) if value is not None else "<missing-id>"


def choose_network_by_ip(
    networks: list[dict[str, Any]], fixed_ip: ipaddress.IPv4Address
) -> dict[str, Any]:
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
        if isinstance(group.get("name"), str)
        and group["name"].strip().lower() in DEFAULT_GROUP_NAMES
    ]
    if len(default_matches) == 1:
        return default_matches[0]

    choices = ", ".join(f"{group.get('name', '<unnamed>')}({_id(group)})" for group in groups)
    raise UnifiError(
        "cannot choose a user group automatically; pass --usergroup-id. "
        f"Available groups: {choices}"
    )


def parse_inventory_reservations(raw_json: str) -> list[ReservationSpec]:
    if not raw_json:
        raise UnifiError(
            "missing inventory reservations; pass --inventory-json or run through "
            "the flake app wrapper"
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
    if not isinstance(start_ip, ipaddress.IPv4Address) or not isinstance(
        end_ip, ipaddress.IPv4Address
    ):
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


def normalize_text_dhcp_option_encoding(value: str, *, label: str) -> str:
    normalized = value.strip().lower()
    if not normalized:
        return "text"
    if normalized in {"text", "string", "plain"}:
        return "text"
    raise UnifiError(f"{label} option encoding must be text")


def normalize_domain_search_option_encoding(value: str) -> str:
    return normalize_text_dhcp_option_encoding(value, label="domain-search")


def normalize_classless_static_routes_option_encoding(value: str) -> str:
    return normalize_text_dhcp_option_encoding(value, label="classless-static-routes")


def normalize_dhcp_option_name(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        raise UnifiError("DHCP option name must not be empty")
    if not re.fullmatch(r"[A-Za-z0-9]+", normalized):
        raise UnifiError(f"DHCP option name must contain only letters and numbers: {value}")
    return normalized


def normalize_dhcp_option_type(value: str) -> str:
    normalized = value.strip().lower()
    if not normalized:
        raise UnifiError("DHCP option type must not be empty")
    if not re.fullmatch(r"[a-z]+", normalized):
        raise UnifiError(f"invalid DHCP option type: {value}")
    return normalized


def normalize_dhcp_option_code(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise UnifiError(f"DHCP option code must be an integer, got: {value!r}")
    if value < 1 or value > 254:
        raise UnifiError(f"DHCP option code must be between 1 and 254, got: {value}")
    return value


def parse_dhcp_custom_option_json(
    raw_json: str,
    *,
    label: str,
    normalize_encoding: Callable[[str], str],
) -> DhcpCustomOptionSpec | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid {label} option JSON: {error}") from error

    if not isinstance(decoded, dict):
        raise UnifiError(f"{label} option JSON must be an object")

    code = normalize_dhcp_option_code(decoded.get("code"))
    name = normalize_dhcp_option_name(str(decoded.get("name", "")))
    option_type = normalize_dhcp_option_type(str(decoded.get("type", "")))
    signed = decoded.get("signed")
    if not isinstance(signed, bool):
        raise UnifiError(f"{label} option JSON must contain boolean signed")

    encoding = normalize_encoding(str(decoded.get("encoding", "")))
    return DhcpCustomOptionSpec(
        code=code,
        name=name,
        option_type=option_type,
        signed=signed,
        encoding=encoding,
    )


def parse_domain_search_option_json(raw_json: str) -> DhcpCustomOptionSpec | None:
    return parse_dhcp_custom_option_json(
        raw_json,
        label="domain-search",
        normalize_encoding=normalize_domain_search_option_encoding,
    )


def parse_classless_static_routes_option_json(
    raw_json: str,
) -> DhcpCustomOptionSpec | None:
    return parse_dhcp_custom_option_json(
        raw_json,
        label="classless-static-routes",
        normalize_encoding=normalize_classless_static_routes_option_encoding,
    )


def parse_static_routes(raw_json: str) -> list[StaticRouteSpec] | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid static routes JSON: {error}") from error

    if not isinstance(decoded, list):
        raise UnifiError("static routes JSON must be a list")

    routes: list[StaticRouteSpec] = []
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise UnifiError(f"static route item {index} is not an object")

        name = item.get("name")
        destination = item.get("destination", item.get("network"))
        next_hop = item.get("nextHop", item.get("next_hop"))
        distance = item.get("distance", 1)
        enabled = item.get("enabled", True)

        if not isinstance(name, str) or not name.strip():
            raise UnifiError(f"static route item {index} is missing name")
        if not isinstance(destination, str):
            raise UnifiError(f"static route item {index} is missing destination")
        if not isinstance(next_hop, str):
            raise UnifiError(f"static route item {index} is missing nextHop")
        if isinstance(distance, bool) or not isinstance(distance, int):
            raise UnifiError(f"static route item {index} has non-integer distance: {distance!r}")
        if distance < 1 or distance > 255:
            raise UnifiError(f"static route item {index} distance must be between 1 and 255")
        if not isinstance(enabled, bool):
            raise UnifiError(f"static route item {index} enabled must be boolean")

        parsed_destination = ipaddress.ip_network(destination, strict=False)
        if not isinstance(parsed_destination, ipaddress.IPv4Network):
            raise UnifiError(f"static route item {index} destination is not IPv4: {destination}")
        parsed_next_hop = ipaddress.ip_address(next_hop)
        if not isinstance(parsed_next_hop, ipaddress.IPv4Address):
            raise UnifiError(f"static route item {index} nextHop is not IPv4: {next_hop}")

        routes.append(
            StaticRouteSpec(
                name=name.strip(),
                destination=parsed_destination,
                next_hop=parsed_next_hop,
                distance=distance,
                enabled=enabled,
            )
        )

    return routes


def parse_classless_static_routes(
    raw_json: str,
) -> tuple[ClasslessStaticRouteSpec, ...] | None:
    if not raw_json:
        return None

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid classless static routes JSON: {error}") from error

    if not isinstance(decoded, list):
        raise UnifiError("classless static routes JSON must be a list")

    routes: list[ClasslessStaticRouteSpec] = []
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise UnifiError(f"classless static route item {index} is not an object")

        enabled = item.get("enabled", True)
        if not isinstance(enabled, bool):
            raise UnifiError(f"classless static route item {index} enabled must be boolean")
        if not enabled:
            continue

        destination = item.get("destination", item.get("network"))
        next_hop = item.get("nextHop", item.get("next_hop", item.get("router")))

        if not isinstance(destination, str):
            raise UnifiError(f"classless static route item {index} is missing destination")
        if not isinstance(next_hop, str):
            raise UnifiError(f"classless static route item {index} is missing nextHop")

        parsed_destination = ipaddress.ip_network(destination, strict=False)
        if not isinstance(parsed_destination, ipaddress.IPv4Network):
            raise UnifiError(
                f"classless static route item {index} destination is not IPv4: {destination}"
            )

        parsed_next_hop = ipaddress.ip_address(next_hop)
        if not isinstance(parsed_next_hop, ipaddress.IPv4Address):
            raise UnifiError(f"classless static route item {index} nextHop is not IPv4: {next_hop}")

        routes.append(
            ClasslessStaticRouteSpec(
                destination=parsed_destination,
                next_hop=parsed_next_hop,
            )
        )

    if not routes:
        return None

    return tuple(routes)


def render_classless_static_routes_option(
    routes: tuple[ClasslessStaticRouteSpec, ...],
) -> str:
    values: list[str] = []
    for route in routes:
        values.extend([str(route.destination), str(route.next_hop)])
    return ",".join(values)


def build_single_reservation(args: Arguments) -> ReservationSpec:
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


def load_reservations(args: Arguments) -> tuple[str, list[ReservationSpec]]:
    if args.no_reservations_update:
        if args.mac or args.ip or args.hostname:
            raise UnifiError(
                "use either --no-reservations-update or single-client reservation "
                "arguments, not both"
            )
        return "disabled", []
    if args.mac or args.ip or args.hostname:
        return "single", [build_single_reservation(args)]
    return "inventory", parse_inventory_reservations(args.inventory_json)
