from __future__ import annotations

import sys
from collections.abc import Sequence
from typing import Any

from .arguments import build_parser
from .client import UnifiLegacyClient
from .dns import parse_records, sync_records
from .errors import UnifiError
from .models import Arguments
from .parsing import (
    _id,
    build_clients_by_mac,
    choose_network_by_ip,
    choose_usergroup,
    format_json,
    load_reservations,
    parse_static_routes,
    render_classless_static_routes_option,
)
from .planning import (
    build_client_update_plan,
    build_network_settings,
    build_network_update_payload,
    build_static_route_update_plan,
    build_static_routes_by_destination,
    ensure_dhcp_custom_option,
    static_route_key,
)


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv, namespace=Arguments())

    try:
        mode, reservations = load_reservations(args)
        network_settings = build_network_settings(args)
        dns_records = None if args.no_dns_records_update else parse_records(args.dns_records_json)
        static_routes = (
            None if args.no_static_routes_update else parse_static_routes(args.static_routes_json)
        )

        client = UnifiLegacyClient(
            base_url=args.base_url,
            api_key=args.api_key,
            site=args.site,
            verify_tls=not args.insecure_tls,
            debug=args.debug,
        )

        networks = client.list_networks()
        clients = client.list_known_clients()
        clients_by_mac = build_clients_by_mac(clients)
        dhcp_range_result: dict[str, Any] | None = None
        dns_records_result: dict[str, Any] | None = None
        static_routes_result: dict[str, Any] | None = None

        if network_settings is not None:
            if args.network_id:
                lookup_ip = None
            elif network_settings.dhcp_range is not None:
                lookup_ip = network_settings.dhcp_range.start
            elif reservations:
                lookup_ip = reservations[0].fixed_ip
            else:
                raise UnifiError(
                    "network settings without DHCP range require reservations or --network-id to choose a network"
                )
            if args.network_id:
                selected_dhcp_network = next(
                    (network for network in networks if network.get("_id") == args.network_id),
                    None,
                )
            else:
                if lookup_ip is None:
                    raise UnifiError("internal error: missing network lookup address")
                selected_dhcp_network = choose_network_by_ip(networks, lookup_ip)
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
                ) = ensure_dhcp_custom_option(
                    client=client,
                    desired=network_settings.domain_search_option,
                    dry_run=args.dry_run,
                )

            classless_static_routes_option_field = None
            classless_static_routes_option_result = None
            if network_settings.classless_static_routes is not None:
                if network_settings.classless_static_routes_option is None:
                    raise UnifiError(
                        "internal error: classless_static_routes present without option specification"
                    )
                (
                    classless_static_routes_option_field,
                    classless_static_routes_option_result,
                ) = ensure_dhcp_custom_option(
                    client=client,
                    desired=network_settings.classless_static_routes_option,
                    dry_run=args.dry_run,
                )

            dhcp_payload, dhcp_changes = build_network_update_payload(
                network_settings,
                selected_dhcp_network,
                domain_search_option_field=domain_search_option_field,
                classless_static_routes_option_field=classless_static_routes_option_field,
            )
            custom_options_changed = bool(
                domain_search_option_result is not None
                and domain_search_option_result["changed"]
                or classless_static_routes_option_result is not None
                and classless_static_routes_option_result["changed"]
            )
            dhcp_changed = bool(dhcp_payload) or custom_options_changed
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
                "domain_search_option_value": (
                    network_settings.domain_search[0]
                    if network_settings.domain_search is not None
                    else None
                ),
                "classless_static_routes": [
                    {
                        "destination": str(route.destination),
                        "next_hop": str(route.next_hop),
                    }
                    for route in network_settings.classless_static_routes or ()
                ],
                "classless_static_routes_option": classless_static_routes_option_result,
                "classless_static_routes_option_value": (
                    render_classless_static_routes_option(network_settings.classless_static_routes)
                    if network_settings.classless_static_routes is not None
                    else None
                ),
                "tftp_server": network_settings.tftp_server,
                "bootfile": network_settings.bootfile,
                "result": dhcp_result,
            }

        if dns_records is not None:
            dns_records_result = sync_records(
                client,
                requested_site=args.site,
                records=dns_records,
                dry_run=args.dry_run,
            )

        if static_routes is not None:
            existing_static_routes = client.list_static_routes()
            existing_routes_by_destination = build_static_routes_by_destination(
                existing_static_routes
            )

            static_route_results: list[dict[str, Any]] = []
            for route in static_routes:
                existing_route = existing_routes_by_destination.get(
                    static_route_key(route.destination)
                )
                action, payload, changes = build_static_route_update_plan(
                    existing_route=existing_route,
                    route=route,
                )
                changed = bool(payload)
                result = None
                if changed and not args.dry_run:
                    if existing_route is None:
                        result = client.create_static_route(payload)
                    else:
                        route_id = _id(existing_route)
                        if route_id == "<missing-id>":
                            raise UnifiError(
                                f"existing UniFi static route for {route.destination} has no _id"
                            )
                        result = client.update_static_route(route_id, payload)

                static_route_results.append(
                    {
                        "name": route.name,
                        "destination": str(route.destination),
                        "next_hop": str(route.next_hop),
                        "distance": route.distance,
                        "enabled": route.enabled,
                        "route_id": _id(existing_route) if existing_route is not None else None,
                        "action": action,
                        "changed": changed,
                        "dry_run": args.dry_run,
                        "changes": changes,
                        "result": result,
                    }
                )

            static_routes_result = {
                "dry_run": args.dry_run,
                "count": len(static_route_results),
                "changed_count": sum(1 for result in static_route_results if result["changed"]),
                "results": static_route_results,
            }

        selected_group: dict[str, Any] | None = None
        allow_inventory_placeholders = mode == "inventory" and not args.no_create_known_clients
        results: list[dict[str, Any]] = []

        for reservation in reservations:
            selected_network = (
                next(
                    (network for network in networks if network.get("_id") == args.network_id),
                    None,
                )
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
            should_create_placeholder = (
                args.create_known_client if mode == "single" else allow_inventory_placeholders
            )
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
                + (dns_records_result["changed_count"] if dns_records_result is not None else 0)
                + (static_routes_result["changed_count"] if static_routes_result is not None else 0)
            ),
            "dhcp_range_update": dhcp_range_result,
            "dns_records_update": dns_records_result,
            "static_routes_update": static_routes_result,
            "results": results,
        }
        print(format_json(summary))
        return 0
    except UnifiError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
