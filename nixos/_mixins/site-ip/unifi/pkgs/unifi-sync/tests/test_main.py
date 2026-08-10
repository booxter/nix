import json

from unifi_sync import cli


INVENTORY = [
    {
        "hostname": "printer",
        "mac": "aa:bb:cc:dd:ee:ff",
        "ip": "192.168.1.20",
    }
]


def comprehensive_args():
    return [
        "--base-url",
        "https://unifi",
        "--api-key",
        "secret",
        "--inventory-json",
        json.dumps(INVENTORY),
        "--dhcp-range-json",
        json.dumps({"start": "192.168.1.100", "end": "192.168.1.200"}),
        "--domain-name",
        "home.arpa",
        "--domain-search-json",
        json.dumps(["home.arpa"]),
        "--domain-search-option-json",
        json.dumps(
            {
                "code": 119,
                "name": "DomainSearch",
                "type": "text",
                "signed": False,
                "encoding": "text",
            }
        ),
        "--classless-static-routes-json",
        json.dumps([{"destination": "10.0.0.0/8", "nextHop": "192.168.1.1"}]),
        "--classless-static-routes-option-json",
        json.dumps(
            {
                "code": 121,
                "name": "ClasslessStaticRoutes",
                "type": "text",
                "signed": False,
                "encoding": "text",
            }
        ),
        "--tftp-server",
        "192.168.1.10",
        "--bootfile",
        "netboot.xyz.efi",
        "--dns-records-json",
        json.dumps(
            [
                {
                    "type": "A_RECORD",
                    "domain": "router.home.arpa",
                    "ttlSeconds": 60,
                    "ipv4Address": "192.168.1.1",
                },
                {
                    "type": "CNAME_RECORD",
                    "domain": "gateway.home.arpa",
                    "ttlSeconds": 60,
                    "targetDomain": "router.home.arpa",
                },
            ]
        ),
        "--static-routes-json",
        json.dumps(
            [
                {
                    "name": "private",
                    "destination": "10.0.0.0/8",
                    "nextHop": "192.168.1.1",
                    "distance": 1,
                }
            ]
        ),
    ]


class ComprehensiveFakeClient:
    instances = []

    def __init__(self, **kwargs):
        self.connection = kwargs
        self.calls = []
        self.instances.append(self)

    def list_networks(self):
        return [
            {
                "_id": "network-1",
                "name": "LAN",
                "ip_subnet": "192.168.1.1/24",
                "dhcpd_enabled": False,
                "dhcpd_start": "192.168.1.50",
                "dhcpd_stop": "192.168.1.99",
                "domain_name": "old.arpa",
                "dhcpd_user_option_domain-option": "old.arpa",
                "dhcpd_user_option_routes-option": "",
                "dhcpd_boot_enabled": False,
                "dhcpd_boot_server": "",
                "dhcpd_boot_filename": "",
            }
        ]

    def list_known_clients(self):
        return [
            {
                "_id": "client-1",
                "mac": "aa:bb:cc:dd:ee:ff",
                "use_fixedip": False,
                "network_id": "old-network",
                "fixed_ip": "192.168.1.19",
                "local_dns_record_enabled": False,
                "local_dns_record": "old-printer",
            }
        ]

    def list_dhcp_options(self):
        return [
            {
                "_id": "domain-option",
                "code": 119,
                "name": "DomainSearch",
                "type": "text",
                "signed": False,
            },
            {
                "_id": "routes-option",
                "code": 121,
                "name": "ClasslessStaticRoutes",
                "type": "text",
                "signed": False,
            },
        ]

    def list_sites(self):
        return [{"id": "site-1", "internalReference": "default", "name": "Default"}]

    def list_dns_policies(self, site_id):
        assert site_id == "site-1"
        return [
            {
                "id": "dns-1",
                "type": "A_RECORD",
                "domain": "router.home.arpa",
                "enabled": True,
                "ttlSeconds": 60,
                "ipv4Address": "192.168.1.1",
            }
        ]

    def list_static_routes(self):
        return [
            {
                "_id": "route-1",
                "enabled": True,
                "name": "private",
                "type": "static-route",
                "static-route_network": "10.0.0.0/8",
                "static-route_type": "nexthop-route",
                "static-route_nexthop": "192.168.1.254",
                "static-route_distance": "1",
            }
        ]

    def update_network(self, network_id, payload):
        self.calls.append(("update_network", network_id, payload))
        return {"updated": network_id}

    def create_dns_policy(self, site_id, payload):
        self.calls.append(("create_dns_policy", site_id, payload))
        return {"created": payload["domain"]}

    def update_dns_policy(self, site_id, policy_id, payload):
        self.calls.append(("update_dns_policy", site_id, policy_id, payload))
        return {"updated": policy_id}

    def update_static_route(self, route_id, payload):
        self.calls.append(("update_static_route", route_id, payload))
        return {"updated": route_id}

    def create_static_route(self, payload):
        self.calls.append(("create_static_route", payload))
        return {"created": payload["name"]}

    def update_client(self, client_id, payload):
        self.calls.append(("update_client", client_id, payload))
        return {"updated": client_id}


def test_main_applies_comprehensive_inventory_plan(monkeypatch, capsys):
    ComprehensiveFakeClient.instances.clear()
    monkeypatch.setattr(cli, "UnifiLegacyClient", ComprehensiveFakeClient)

    assert cli.main(comprehensive_args()) == 0

    summary = json.loads(capsys.readouterr().out)
    assert summary["mode"] == "inventory"
    assert summary["changed_count"] == 4
    assert summary["reservation_changed_count"] == 1
    assert summary["dhcp_range_update"]["changed"] is True
    assert summary["dns_records_update"]["changed_count"] == 1
    assert summary["static_routes_update"]["changed_count"] == 1

    client = ComprehensiveFakeClient.instances[0]
    assert client.connection == {
        "base_url": "https://unifi",
        "api_key": "secret",
        "site": "default",
        "verify_tls": True,
        "debug": False,
    }
    assert [call[0] for call in client.calls] == [
        "update_network",
        "create_dns_policy",
        "update_static_route",
        "update_client",
    ]


class MissingClientFake(ComprehensiveFakeClient):
    def list_known_clients(self):
        return []

    def list_usergroups(self):
        return [{"_id": "group-1", "name": "Default"}]

    def unexpected_mutation(self, *args, **kwargs):
        raise AssertionError("dry-run attempted to mutate UniFi")

    create_known_client = unexpected_mutation
    update_client = unexpected_mutation


def test_main_dry_run_plans_missing_inventory_client(monkeypatch, capsys):
    MissingClientFake.instances.clear()
    monkeypatch.setattr(cli, "UnifiLegacyClient", MissingClientFake)
    args = [
        "--base-url",
        "https://unifi",
        "--api-key",
        "secret",
        "--inventory-json",
        json.dumps(INVENTORY),
        "--dry-run",
        "--no-dhcp-range-update",
        "--no-classless-static-routes-update",
        "--no-netboot-update",
        "--no-dns-records-update",
        "--no-static-routes-update",
    ]

    assert cli.main(args) == 0

    summary = json.loads(capsys.readouterr().out)
    assert summary["changed_count"] == 1
    assert summary["results"][0]["would_create_placeholder"] is True
    assert summary["results"][0]["dry_run"] is True


def test_main_reports_validation_errors(capsys):
    assert cli.main(["--base-url", "https://unifi", "--api-key", "secret"]) == 1

    assert "missing inventory reservations" in capsys.readouterr().err
