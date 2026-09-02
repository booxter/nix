from __future__ import annotations

import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

from .arguments import build_parser
from .client import UnifiLegacyClient
from .dns import parse_records, sync_records
from .errors import UnifiError
from .models import (
    Arguments,
    DhcpCustomOptionSpec,
    NetworkDhcpSettingsSpec,
    ReservationSpec,
    StaticRouteSpec,
)
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


def _select_dhcp_network(
    args: Arguments,
    settings: NetworkDhcpSettingsSpec,
    reservations: list[ReservationSpec],
    networks: list[dict[str, Any]],
) -> dict[str, Any]:
    if args.network_id:
        selected = next(
            (network for network in networks if network.get("_id") == args.network_id),
            None,
        )
    elif settings.dhcp_range is not None:
        selected = choose_network_by_ip(networks, settings.dhcp_range.start)
    elif reservations:
        selected = choose_network_by_ip(networks, reservations[0].fixed_ip)
    else:
        raise UnifiError(
            "network settings without DHCP range require reservations or --network-id "
            "to choose a network"
        )
    if selected is None:
        raise UnifiError(f"network not found: {args.network_id}")
    return selected


def _ensure_custom_option(
    client: UnifiLegacyClient,
    desired: DhcpCustomOptionSpec | None,
    *,
    enabled: bool,
    dry_run: bool,
    label: str,
) -> tuple[str | None, dict[str, Any] | None]:
    if not enabled:
        return None, None
    if desired is None:
        raise UnifiError(f"internal error: {label} present without option specification")
    return ensure_dhcp_custom_option(client=client, desired=desired, dry_run=dry_run)


def _sync_network_settings(
    client: UnifiLegacyClient,
    args: Arguments,
    settings: NetworkDhcpSettingsSpec,
    reservations: list[ReservationSpec],
    networks: list[dict[str, Any]],
) -> dict[str, Any]:
    selected_network = _select_dhcp_network(args, settings, reservations, networks)
    network_id = _id(selected_network)
    if network_id == "<missing-id>":
        raise UnifiError("selected DHCP network has no _id")
    domain_option_field, domain_option_result = _ensure_custom_option(
        client,
        settings.domain_search_option,
        enabled=settings.domain_search is not None,
        dry_run=args.dry_run,
        label="domain_search",
    )
    routes_option_field, routes_option_result = _ensure_custom_option(
        client,
        settings.classless_static_routes_option,
        enabled=settings.classless_static_routes is not None,
        dry_run=args.dry_run,
        label="classless_static_routes",
    )
    payload, changes = build_network_update_payload(
        settings,
        selected_network,
        domain_search_option_field=domain_option_field,
        classless_static_routes_option_field=routes_option_field,
    )
    options_changed = bool(
        (domain_option_result is not None and domain_option_result["changed"])
        or (routes_option_result is not None and routes_option_result["changed"])
    )
    changed = bool(payload) or options_changed
    result = None
    if changed and not args.dry_run:
        result = client.update_network(network_id=network_id, payload=payload)
    return {
        "network_id": network_id,
        "network_name": selected_network.get("name"),
        "changed": changed,
        "dry_run": args.dry_run,
        "changes": changes,
        "start": str(settings.dhcp_range.start) if settings.dhcp_range is not None else None,
        "end": str(settings.dhcp_range.end) if settings.dhcp_range is not None else None,
        "domain_name": settings.domain_name,
        "domain_search": (
            list(settings.domain_search) if settings.domain_search is not None else None
        ),
        "domain_search_option": domain_option_result,
        "domain_search_option_value": (
            settings.domain_search[0] if settings.domain_search is not None else None
        ),
        "classless_static_routes": [
            {"destination": str(route.destination), "next_hop": str(route.next_hop)}
            for route in settings.classless_static_routes or ()
        ],
        "classless_static_routes_option": routes_option_result,
        "classless_static_routes_option_value": (
            render_classless_static_routes_option(settings.classless_static_routes)
            if settings.classless_static_routes is not None
            else None
        ),
        "tftp_server": settings.tftp_server,
        "bootfile": settings.bootfile,
        "result": result,
    }


def _sync_static_routes(
    client: UnifiLegacyClient,
    args: Arguments,
    routes: list[StaticRouteSpec],
) -> dict[str, Any]:
    existing_by_destination = build_static_routes_by_destination(client.list_static_routes())
    results: list[dict[str, Any]] = []
    for route in routes:
        existing = existing_by_destination.get(static_route_key(route.destination))
        action, payload, changes = build_static_route_update_plan(
            existing_route=existing,
            route=route,
        )
        changed = bool(payload)
        result = None
        if changed and not args.dry_run:
            if existing is None:
                result = client.create_static_route(payload)
            else:
                route_id = _id(existing)
                if route_id == "<missing-id>":
                    raise UnifiError(
                        f"existing UniFi static route for {route.destination} has no _id"
                    )
                result = client.update_static_route(route_id, payload)
        results.append(
            {
                "name": route.name,
                "destination": str(route.destination),
                "next_hop": str(route.next_hop),
                "distance": route.distance,
                "enabled": route.enabled,
                "route_id": _id(existing) if existing is not None else None,
                "action": action,
                "changed": changed,
                "dry_run": args.dry_run,
                "changes": changes,
                "result": result,
            }
        )
    return {
        "dry_run": args.dry_run,
        "count": len(results),
        "changed_count": sum(1 for result in results if result["changed"]),
        "results": results,
    }


@dataclass
class _ReservationSynchronizer:
    client: UnifiLegacyClient
    args: Arguments
    mode: str
    networks: list[dict[str, Any]]
    clients_by_mac: dict[str, dict[str, Any]]
    selected_group: dict[str, Any] | None = None

    def _network(self, reservation: ReservationSpec) -> tuple[dict[str, Any], str]:
        selected = (
            next(
                (
                    network
                    for network in self.networks
                    if network.get("_id") == self.args.network_id
                ),
                None,
            )
            if self.args.network_id
            else choose_network_by_ip(self.networks, reservation.fixed_ip)
        )
        if selected is None:
            raise UnifiError(f"network not found: {self.args.network_id}")
        network_id = _id(selected)
        if network_id == "<missing-id>":
            raise UnifiError("selected network has no _id")
        return selected, network_id

    def _local_dns_record(self, reservation: ReservationSpec) -> str | None:
        if self.args.no_local_dns_record:
            return None
        return reservation.hostname

    def _known_client(
        self,
        reservation: ReservationSpec,
    ) -> tuple[dict[str, Any] | None, bool, bool]:
        existing = self.clients_by_mac.get(reservation.mac)
        allow_inventory = self.mode == "inventory" and not self.args.no_create_known_clients
        should_create = self.args.create_known_client if self.mode == "single" else allow_inventory
        if existing is not None or not should_create:
            return existing, False, should_create
        # TODO: Re-check on a live UCG whether placeholder-only known clients
        # behave identically to observed clients for fixed IP + Local DNS Record.
        if self.selected_group is None:
            self.selected_group = choose_usergroup(
                self.client.list_usergroups(),
                self.args.usergroup_id,
            )
        if self.args.dry_run:
            return None, False, should_create
        self.client.create_known_client(
            mac=reservation.mac,
            usergroup_id=_id(self.selected_group),
            client_name=reservation.hostname or self.args.client_name,
        )
        self.clients_by_mac = build_clients_by_mac(self.client.list_known_clients())
        return self.clients_by_mac.get(reservation.mac), True, should_create

    def _dry_run_placeholder(
        self,
        reservation: ReservationSpec,
        network: dict[str, Any],
        network_id: str,
    ) -> dict[str, Any]:
        local_dns_record = self._local_dns_record(reservation)
        payload, changes = build_client_update_plan(
            existing_client={},
            network_id=network_id,
            fixed_ip=reservation.fixed_ip,
            local_dns_record=local_dns_record,
        )
        return {
            "hostname": reservation.hostname,
            "mac": reservation.mac,
            "fixed_ip": str(reservation.fixed_ip),
            "client_id": None,
            "network_id": network_id,
            "network_name": network.get("name"),
            "created_placeholder": False,
            "would_create_placeholder": True,
            "changed": bool(payload),
            "dry_run": True,
            "changes": changes,
            "local_dns_record": local_dns_record,
            "result": None,
        }

    def sync(self, reservation: ReservationSpec) -> dict[str, Any]:
        network, network_id = self._network(reservation)
        existing, created_placeholder, should_create = self._known_client(reservation)
        if existing is None:
            if should_create and self.args.dry_run:
                return self._dry_run_placeholder(reservation, network, network_id)
            raise UnifiError(
                f"known client not found for {reservation.mac}. "
                "Retry with --create-known-client or without --no-create-known-clients."
            )
        client_id = _id(existing)
        if client_id == "<missing-id>":
            raise UnifiError(f"client record for {reservation.mac} has no _id")
        local_dns_record = self._local_dns_record(reservation)
        payload, changes = build_client_update_plan(
            existing_client=existing,
            network_id=network_id,
            fixed_ip=reservation.fixed_ip,
            local_dns_record=local_dns_record,
        )
        changed = bool(payload)
        result = None
        if changed and not self.args.dry_run:
            result = self.client.update_client(client_id=client_id, payload=payload)
        return {
            "hostname": reservation.hostname,
            "mac": reservation.mac,
            "fixed_ip": str(reservation.fixed_ip),
            "client_id": client_id,
            "network_id": network_id,
            "network_name": network.get("name"),
            "created_placeholder": created_placeholder,
            "would_create_placeholder": False,
            "changed": changed,
            "dry_run": self.args.dry_run,
            "changes": changes,
            "local_dns_record": local_dns_record,
            "result": result,
        }


def _run(args: Arguments) -> int:
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
    dhcp_result = (
        _sync_network_settings(client, args, network_settings, reservations, networks)
        if network_settings is not None
        else None
    )
    dns_result = (
        sync_records(
            client,
            requested_site=args.site,
            records=dns_records,
            dry_run=args.dry_run,
        )
        if dns_records is not None
        else None
    )
    static_routes_result = (
        _sync_static_routes(client, args, static_routes) if static_routes is not None else None
    )
    synchronizer = _ReservationSynchronizer(
        client=client,
        args=args,
        mode=mode,
        networks=networks,
        clients_by_mac=build_clients_by_mac(clients),
    )
    results = [synchronizer.sync(reservation) for reservation in reservations]
    reservation_changed_count = sum(1 for result in results if result["changed"])
    summary = {
        "site": args.site,
        "mode": mode,
        "dry_run": args.dry_run,
        "count": len(results),
        "reservation_changed_count": reservation_changed_count,
        "changed_count": (
            reservation_changed_count
            + (1 if dhcp_result is not None and dhcp_result["changed"] else 0)
            + (dns_result["changed_count"] if dns_result is not None else 0)
            + (static_routes_result["changed_count"] if static_routes_result is not None else 0)
        ),
        "dhcp_range_update": dhcp_result,
        "dns_records_update": dns_result,
        "static_routes_update": static_routes_result,
        "results": results,
    }
    print(format_json(summary))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv, namespace=Arguments())
    try:
        return _run(args)
    except UnifiError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
