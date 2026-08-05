from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol, cast

# pyroute2 does not publish a py.typed marker in nixpkgs.
from pyroute2 import IPRoute  # type: ignore[import-untyped]
from pyroute2.netlink.exceptions import NetlinkError  # type: ignore[import-untyped]

from .errors import ControllerError


class NetlinkMessage(Protocol):
    def get_attr(self, name: str) -> object: ...


class NetlinkRoute(Protocol):
    def route(
        self,
        command: str,
        **attributes: object,
    ) -> Sequence[NetlinkMessage]: ...

    def get_links(self, *indexes: int) -> Sequence[NetlinkMessage]: ...

    def link_lookup(self, **attributes: object) -> Sequence[int]: ...

    def tc(
        self,
        command: str,
        kind: str,
        index: int,
        handle: str,
        **attributes: object,
    ) -> object: ...

    def close(self) -> None: ...


class TrafficControl(Protocol):
    def default_egress_interface(self, route_probe_address: str) -> str: ...

    def apply_shape(self, interface: str, rate: str) -> None: ...


@dataclass
class PyrouteTrafficControl:
    netlink: NetlinkRoute

    @classmethod
    def open(cls) -> PyrouteTrafficControl:
        return cls(cast(NetlinkRoute, IPRoute()))

    def close(self) -> None:
        self.netlink.close()

    def default_egress_interface(self, route_probe_address: str) -> str:
        try:
            routes = self.netlink.route("get", dst=route_probe_address)
        except (NetlinkError, OSError) as error:
            raise ControllerError(
                f"failed to resolve route to {route_probe_address}: {error}"
            ) from error
        if not routes:
            raise ControllerError(f"no route found for probe address {route_probe_address}")

        interface_index = routes[0].get_attr("RTA_OIF")
        if not isinstance(interface_index, int) or isinstance(interface_index, bool):
            raise ControllerError("default route has no output interface")

        try:
            links = self.netlink.get_links(interface_index)
        except (NetlinkError, OSError) as error:
            raise ControllerError(
                f"failed to resolve interface {interface_index}: {error}"
            ) from error
        if not links:
            raise ControllerError(f"interface {interface_index} was not found")
        interface = links[0].get_attr("IFLA_IFNAME")
        if not isinstance(interface, str) or not interface:
            raise ControllerError(f"interface {interface_index} has no name")
        return interface

    def apply_shape(self, interface: str, rate: str) -> None:
        try:
            indexes = self.netlink.link_lookup(ifname=interface)
            if not indexes:
                raise ControllerError(f"interface {interface} was not found")
            interface_index = indexes[0]

            self.netlink.tc(
                "change-class",
                "htb",
                interface_index,
                "1:10",
                parent="1:1",
                rate=rate,
                ceil=rate,
            )
            self.netlink.tc(
                "change",
                "cake",
                interface_index,
                "10:",
                parent="1:10",
                bandwidth=rate,
                diffserv_mode="besteffort",
                wash=True,
            )
        except ControllerError:
            raise
        except (NetlinkError, OSError) as error:
            raise ControllerError(f"failed to shape {interface} at {rate}: {error}") from error
