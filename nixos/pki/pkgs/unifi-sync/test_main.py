import importlib.util
import os
import pathlib
import sys

import pytest


MODULE_PATH = pathlib.Path(
    os.environ.get("UNIFI_SYNC_MAIN", pathlib.Path(__file__).with_name("main.py"))
)
SPEC = importlib.util.spec_from_file_location("unifi_sync", MODULE_PATH)
unifi_sync = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = unifi_sync
SPEC.loader.exec_module(unifi_sync)


def test_tls_verification_is_default():
    args = unifi_sync.build_parser().parse_args([])

    assert args.insecure_tls is False


def test_insecure_tls_requires_explicit_option():
    args = unifi_sync.build_parser().parse_args(["--insecure-tls"])

    assert args.insecure_tls is True


def test_render_classless_static_routes_option():
    routes = unifi_sync.parse_classless_static_routes(
        """
        [
          {"destination": "10.0.0.0/8", "nextHop": "192.0.2.1"},
          {"destination": "0.0.0.0/0", "nextHop": "192.0.2.254"}
        ]
        """
    )

    value = unifi_sync.render_classless_static_routes_option(routes)

    assert value == "10.0.0.0/8,192.0.2.1,0.0.0.0/0,192.0.2.254"


def test_parse_classless_static_routes_skips_disabled_entries():
    routes = unifi_sync.parse_classless_static_routes(
        """
        [
          {"destination": "10.0.0.0/8", "nextHop": "192.0.2.1", "enabled": false},
          {"destination": "0.0.0.0/0", "router": "192.0.2.254"}
        ]
        """
    )

    assert [str(route.destination) for route in routes] == ["0.0.0.0/0"]
    assert [str(route.next_hop) for route in routes] == ["192.0.2.254"]


def test_classless_static_routes_option_rejects_hex_encoding():
    with pytest.raises(
        unifi_sync.UnifiError,
        match="classless-static-routes option encoding must be text",
    ):
        unifi_sync.parse_classless_static_routes_option_json(
            """
            {
              "code": 121,
              "name": "ClasslessStaticRoutes",
              "type": "text",
              "signed": false,
              "encoding": "hex"
            }
            """
        )


def test_domain_search_option_rejects_hex_encoding():
    with pytest.raises(
        unifi_sync.UnifiError,
        match="domain-search option encoding must be text",
    ):
        unifi_sync.parse_domain_search_option_json(
            """
            {
              "code": 119,
              "name": "DomainSearch",
              "type": "text",
              "signed": false,
              "encoding": "hex"
            }
            """
        )


def test_build_network_update_payload_writes_custom_option_fields():
    settings = unifi_sync.NetworkDhcpSettingsSpec(
        dhcp_range=None,
        domain_name=None,
        domain_search=("example.test",),
        domain_search_option=unifi_sync.DhcpCustomOptionSpec(
            code=119,
            name="DomainSearch",
            option_type="text",
            signed=False,
            encoding="text",
        ),
        classless_static_routes=unifi_sync.parse_classless_static_routes(
            """
            [
              {"destination": "10.0.0.0/8", "nextHop": "192.0.2.1"},
              {"destination": "0.0.0.0/0", "nextHop": "192.0.2.254"}
            ]
            """
        ),
        classless_static_routes_option=unifi_sync.DhcpCustomOptionSpec(
            code=121,
            name="ClasslessStaticRoutes",
            option_type="text",
            signed=False,
            encoding="text",
        ),
        tftp_server=None,
        bootfile=None,
    )

    payload, changes = unifi_sync.build_network_update_payload(
        settings,
        current_network={
            "dhcpd_user_option_domain": "",
            "dhcpd_user_option_routes": "",
        },
        domain_search_option_field="dhcpd_user_option_domain",
        classless_static_routes_option_field="dhcpd_user_option_routes",
    )

    assert payload == {
        "dhcpd_user_option_domain": "example.test",
        "dhcpd_user_option_routes": "10.0.0.0/8,192.0.2.1,0.0.0.0/0,192.0.2.254",
    }
    assert changes["dhcpd_user_option_routes"]["desired_routes"] == [
        {"destination": "10.0.0.0/8", "next_hop": "192.0.2.1"},
        {"destination": "0.0.0.0/0", "next_hop": "192.0.2.254"},
    ]
