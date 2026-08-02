import ipaddress

import pytest

from unifi_sync import cli


def a_record(address="192.168.1.1", ttl=60):
    return cli.DnsRecordSpec(
        record_type="A_RECORD",
        domain="router.home.arpa",
        ttl_seconds=ttl,
        ipv4_address=ipaddress.IPv4Address(address),
    )


def static_route(next_hop="192.168.1.1", distance=1):
    return cli.StaticRouteSpec(
        name="private",
        destination=ipaddress.IPv4Network("10.0.0.0/8"),
        next_hop=ipaddress.IPv4Address(next_hop),
        distance=distance,
    )


def test_dns_policy_update_plan_covers_create_noop_and_update():
    record = a_record()

    action, payload, changes = cli.build_dns_policy_update_plan(None, record)
    assert action == "create"
    assert payload["ipv4Address"] == "192.168.1.1"
    assert changes["domain"] == {
        "current": None,
        "desired": "router.home.arpa",
    }

    existing = {
        "id": "dns-1",
        "type": "A_RECORD",
        "domain": "router.home.arpa",
        "enabled": True,
        "ttlSeconds": 60,
        "ipv4Address": "192.168.1.1",
    }
    assert cli.build_dns_policy_update_plan(existing, record) == ("noop", {}, {})

    action, payload, changes = cli.build_dns_policy_update_plan(
        existing, a_record(address="192.168.1.2", ttl=120)
    )
    assert action == "update"
    assert payload["ipv4Address"] == "192.168.1.2"
    assert changes == {
        "ttlSeconds": {"current": 60, "desired": 120},
        "ipv4Address": {
            "current": "192.168.1.1",
            "desired": "192.168.1.2",
        },
    }


def test_static_route_update_plan_covers_create_noop_and_update():
    route = static_route()
    action, payload, changes = cli.build_static_route_update_plan(None, route)
    assert action == "create"
    assert payload["static-route_network"] == "10.0.0.0/8"
    assert changes["static-route_nexthop"]["current"] is None

    existing = payload | {"_id": "route-1"}
    assert cli.build_static_route_update_plan(existing, route) == ("noop", {}, {})

    action, payload, changes = cli.build_static_route_update_plan(
        existing, static_route(next_hop="192.168.1.254", distance=5)
    )
    assert action == "update"
    assert payload["static-route_nexthop"] == "192.168.1.254"
    assert changes["static-route_distance"] == {
        "current": "1",
        "desired": "5",
    }


def test_client_update_plan_only_changes_drifted_fields():
    payload, changes = cli.build_client_update_plan(
        existing_client={
            "use_fixedip": True,
            "network_id": "lan",
            "fixed_ip": "192.168.1.20",
            "local_dns_record_enabled": False,
            "local_dns_record": "old-name",
        },
        network_id="lan",
        fixed_ip=ipaddress.IPv4Address("192.168.1.20"),
        local_dns_record="printer",
    )

    assert payload == {
        "local_dns_record_enabled": True,
        "local_dns_record": "printer",
    }
    assert set(changes) == {"local_dns_record_enabled", "local_dns_record"}


def test_build_clients_by_mac_normalizes_and_skips_bad_records():
    clients = cli.build_clients_by_mac(
        [
            {"_id": "good", "mac": "AA-BB-CC-DD-EE-FF"},
            {"_id": "invalid", "mac": "not-a-mac"},
            {"_id": "missing"},
        ]
    )

    assert clients == {"aa:bb:cc:dd:ee:ff": {"_id": "good", "mac": "AA-BB-CC-DD-EE-FF"}}


def test_build_dns_policies_by_key_rejects_duplicates():
    policies = [
        {"id": "one", "type": "A_RECORD", "domain": "router.home.arpa"},
        {"id": "two", "type": "a_record", "domain": "Router.HOME.ARPA."},
    ]

    with pytest.raises(cli.UnifiError, match="multiple UniFi DNS policies"):
        cli.build_dns_policies_by_key(policies)


def test_choose_existing_dhcp_option_prefers_exact_definition():
    desired = cli.DhcpCustomOptionSpec(
        code=119,
        name="DomainSearch",
        option_type="text",
        signed=False,
        encoding="text",
    )
    exact = {
        "_id": "exact",
        "code": 119,
        "name": "DomainSearch",
        "type": "text",
        "signed": False,
    }
    options = {
        119: [
            exact,
            {
                "_id": "other",
                "code": 119,
                "name": "Other",
                "type": "text",
                "signed": False,
            },
        ]
    }

    assert cli.choose_existing_dhcp_option(options, desired) is exact


class FakeDhcpOptionClient:
    def __init__(self, options):
        self.options = options
        self.created = []

    def list_dhcp_options(self):
        return self.options

    def create_dhcp_option(self, payload):
        self.created.append(payload)
        return {"_id": "new-option", **payload}


def test_ensure_dhcp_custom_option_reports_dry_run_without_mutation():
    desired = cli.DhcpCustomOptionSpec(
        code=121,
        name="ClasslessStaticRoutes",
        option_type="text",
        signed=False,
        encoding="text",
    )
    client = FakeDhcpOptionClient([])

    field_name, result = cli.ensure_dhcp_custom_option(client, desired, dry_run=True)

    assert field_name is None
    assert result["would_create"] is True
    assert client.created == []


def test_ensure_dhcp_custom_option_creates_missing_definition():
    desired = cli.DhcpCustomOptionSpec(
        code=121,
        name="ClasslessStaticRoutes",
        option_type="text",
        signed=False,
        encoding="text",
    )
    client = FakeDhcpOptionClient([])

    field_name, result = cli.ensure_dhcp_custom_option(client, desired, dry_run=False)

    assert field_name == "dhcpd_user_option_new-option"
    assert result["created"] is True
    assert client.created == [
        {
            "code": 121,
            "name": "ClasslessStaticRoutes",
            "type": "text",
            "signed": False,
        }
    ]


def test_network_update_payload_covers_dhcp_domain_and_netboot():
    settings = cli.NetworkDhcpSettingsSpec(
        dhcp_range=cli.DhcpRangeSpec(
            start=ipaddress.IPv4Address("192.168.1.100"),
            end=ipaddress.IPv4Address("192.168.1.200"),
        ),
        domain_name="home.arpa",
        domain_search=None,
        domain_search_option=None,
        classless_static_routes=None,
        classless_static_routes_option=None,
        tftp_server="192.168.1.10",
        bootfile="netboot.xyz.efi",
    )

    payload, changes = cli.build_network_update_payload(
        settings,
        current_network={
            "dhcpd_enabled": False,
            "dhcpd_start": "192.168.1.50",
            "dhcpd_stop": "192.168.1.99",
            "domain_name": "old.arpa",
            "dhcpd_boot_enabled": False,
        },
        domain_search_option_field=None,
        classless_static_routes_option_field=None,
    )

    assert payload == {
        "dhcpd_enabled": True,
        "dhcpd_start": "192.168.1.100",
        "dhcpd_stop": "192.168.1.200",
        "domain_name": "home.arpa",
        "dhcpd_boot_enabled": True,
        "dhcpd_boot_server": "192.168.1.10",
        "dhcpd_boot_filename": "netboot.xyz.efi",
    }
    assert set(changes) == set(payload)
