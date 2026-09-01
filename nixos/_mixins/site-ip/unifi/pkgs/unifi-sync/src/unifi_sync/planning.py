from __future__ import annotations

import ipaddress
from typing import Any

from .client import UnifiLegacyClient
from .errors import UnifiError
from .models import (
    Arguments,
    DhcpCustomOptionSpec,
    DhcpRangeSpec,
    NetworkDhcpSettingsSpec,
    StaticRouteSpec,
)
from .parsing import (
    _id,
    normalize_bootfile,
    normalize_tftp_server,
    parse_classless_static_routes,
    parse_classless_static_routes_option_json,
    parse_dhcp_range,
    parse_domain_search,
    parse_domain_search_option_json,
    render_classless_static_routes_option,
)


def build_network_dhcp_payload(dhcp_range: DhcpRangeSpec) -> dict[str, Any]:
    return {
        "dhcpd_enabled": True,
        "dhcpd_start": str(dhcp_range.start),
        "dhcpd_stop": str(dhcp_range.end),
    }


def build_network_settings(
    args: Arguments,
) -> NetworkDhcpSettingsSpec | None:
    dhcp_range = None if args.no_dhcp_range_update else parse_dhcp_range(args.dhcp_range_json)
    domain_name = args.domain_name.strip() or None
    domain_search = parse_domain_search(args.domain_search_json)
    domain_search_option = parse_domain_search_option_json(args.domain_search_option_json)

    classless_static_routes = (
        None
        if args.no_classless_static_routes_update
        else parse_classless_static_routes(args.classless_static_routes_json)
    )
    classless_static_routes_option = parse_classless_static_routes_option_json(
        args.classless_static_routes_option_json
    )

    raw_tftp_server = None if args.no_netboot_update else (args.tftp_server.strip() or None)
    raw_bootfile = None if args.no_netboot_update else (args.bootfile.strip() or None)
    if (raw_tftp_server is None) != (raw_bootfile is None):
        raise UnifiError("network boot requires both --tftp-server and --bootfile together")
    tftp_server = normalize_tftp_server(raw_tftp_server) if raw_tftp_server is not None else None
    bootfile = normalize_bootfile(raw_bootfile) if raw_bootfile is not None else None
    if domain_search is not None and domain_search_option is None:
        domain_search = None
    if classless_static_routes is not None and classless_static_routes_option is None:
        classless_static_routes = None

    if (
        dhcp_range is None
        and domain_name is None
        and domain_search is None
        and classless_static_routes is None
        and tftp_server is None
    ):
        return None

    return NetworkDhcpSettingsSpec(
        dhcp_range=dhcp_range,
        domain_name=domain_name,
        domain_search=domain_search,
        domain_search_option=domain_search_option,
        classless_static_routes=classless_static_routes,
        classless_static_routes_option=classless_static_routes_option,
        tftp_server=tftp_server,
        bootfile=bootfile,
    )


def stringify(value: object) -> str | None:
    return None if value is None else str(value)


def build_change(current: object, desired: object) -> dict[str, object]:
    return {
        "current": current,
        "desired": desired,
    }


def static_route_key(destination: ipaddress.IPv4Network) -> str:
    return str(destination)


def get_static_route_destination(route: dict[str, Any]) -> ipaddress.IPv4Network | None:
    for key in ("static-route_network", "network", "destination"):
        value = route.get(key)
        if not isinstance(value, str):
            continue
        try:
            parsed = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if isinstance(parsed, ipaddress.IPv4Network):
            return parsed
    return None


def build_static_routes_by_destination(
    routes: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    by_destination: dict[str, dict[str, Any]] = {}
    for route in routes:
        destination = get_static_route_destination(route)
        if destination is None:
            continue

        key = static_route_key(destination)
        if key in by_destination:
            first = by_destination[key]
            raise UnifiError(
                f"multiple UniFi static routes share destination {key}: {_id(first)}, {_id(route)}"
            )
        by_destination[key] = route
    return by_destination


def build_static_route_payload(route: StaticRouteSpec) -> dict[str, Any]:
    return {
        "enabled": route.enabled,
        "name": route.name,
        "type": "static-route",
        "static-route_network": str(route.destination),
        "static-route_type": "nexthop-route",
        "static-route_nexthop": str(route.next_hop),
        "static-route_distance": str(route.distance),
    }


def build_static_route_update_plan(
    existing_route: dict[str, Any] | None,
    route: StaticRouteSpec,
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    desired_payload = build_static_route_payload(route)
    changes: dict[str, Any] = {}

    if existing_route is None:
        for key, value in desired_payload.items():
            changes[key] = build_change(None, value)
        return "create", desired_payload, changes

    payload: dict[str, Any] = {}

    current_enabled = bool(existing_route.get("enabled"))
    if current_enabled != route.enabled:
        payload["enabled"] = route.enabled
        changes["enabled"] = build_change(current_enabled, route.enabled)

    current_name = stringify(existing_route.get("name"))
    if current_name != route.name:
        payload["name"] = route.name
        changes["name"] = build_change(current_name, route.name)

    current_type = stringify(existing_route.get("type"))
    if current_type != "static-route":
        payload["type"] = "static-route"
        changes["type"] = build_change(current_type, "static-route")

    desired_network = str(route.destination)
    current_network = stringify(
        existing_route.get("static-route_network", existing_route.get("network"))
    )
    if current_network != desired_network:
        payload["static-route_network"] = desired_network
        changes["static-route_network"] = build_change(current_network, desired_network)

    current_route_type = stringify(existing_route.get("static-route_type"))
    if current_route_type != "nexthop-route":
        payload["static-route_type"] = "nexthop-route"
        changes["static-route_type"] = build_change(current_route_type, "nexthop-route")

    desired_next_hop = str(route.next_hop)
    current_next_hop = stringify(
        existing_route.get("static-route_nexthop", existing_route.get("nexthop"))
    )
    if current_next_hop != desired_next_hop:
        payload["static-route_nexthop"] = desired_next_hop
        changes["static-route_nexthop"] = build_change(current_next_hop, desired_next_hop)

    desired_distance = str(route.distance)
    current_distance = stringify(
        existing_route.get("static-route_distance", existing_route.get("distance"))
    )
    if current_distance != desired_distance:
        payload["static-route_distance"] = desired_distance
        changes["static-route_distance"] = build_change(current_distance, desired_distance)

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
            f"multiple UniFi DHCP option definitions match code {desired.code} "
            f"and name {desired.name}"
        )

    if len(candidates) == 1:
        return candidates[0]

    choices = ", ".join(
        f"{option.get('name', '<unnamed>')}({_id(option)} "
        f"type={option.get('type')} signed={option.get('signed')})"
        for option in candidates
    )
    raise UnifiError(
        f"multiple UniFi DHCP option definitions share code {desired.code}; "
        "refine the desired definition. "
        f"Available: {choices}"
    )


def ensure_dhcp_custom_option(
    client: UnifiLegacyClient,
    desired: DhcpCustomOptionSpec,
    dry_run: bool,
) -> tuple[str | None, dict[str, Any]]:
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
        raise UnifiError(f"created UniFi DHCP option definition for code {desired.code} has no _id")
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
    classless_static_routes_option_field: str | None,
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
        if settings.domain_search_option is None:
            raise UnifiError("internal error: domain_search present without option spec")

        if domain_search_option_field is not None:
            current_option_value = stringify(current_network.get(domain_search_option_field))

            if settings.domain_search_option.encoding != "text":
                raise UnifiError("domain-search option encoding must be text")
            if len(settings.domain_search) != 1:
                raise UnifiError("domain-search option currently supports exactly one domain")
            desired_networkconf_value = settings.domain_search[0]

            if current_option_value != desired_networkconf_value:
                payload[domain_search_option_field] = desired_networkconf_value
                changes[domain_search_option_field] = {
                    "current": current_option_value,
                    "desired": desired_networkconf_value,
                    "desired_domains": list(settings.domain_search),
                    "encoding": settings.domain_search_option.encoding,
                }

    if settings.classless_static_routes is not None:
        if settings.classless_static_routes_option is None:
            raise UnifiError("internal error: classless_static_routes present without option spec")

        if classless_static_routes_option_field is not None:
            current_option_value = stringify(
                current_network.get(classless_static_routes_option_field)
            )
            if settings.classless_static_routes_option.encoding != "text":
                raise UnifiError("classless-static-routes option encoding must be text")
            desired_networkconf_value = render_classless_static_routes_option(
                settings.classless_static_routes
            )

            if current_option_value != desired_networkconf_value:
                payload[classless_static_routes_option_field] = desired_networkconf_value
                changes[classless_static_routes_option_field] = {
                    "current": current_option_value,
                    "desired": desired_networkconf_value,
                    "desired_routes": [
                        {
                            "destination": str(route.destination),
                            "next_hop": str(route.next_hop),
                        }
                        for route in settings.classless_static_routes
                    ],
                    "encoding": settings.classless_static_routes_option.encoding,
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
