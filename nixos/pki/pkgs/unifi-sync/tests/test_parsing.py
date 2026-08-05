import ipaddress

import pytest

from unifi_sync import cli, dns


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("AA-BB-CC-DD-EE-FF", "aa:bb:cc:dd:ee:ff"),
        ("aabb.ccdd.eeff", "aa:bb:cc:dd:ee:ff"),
        ("aa:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff"),
    ],
)
def test_normalize_mac(value, expected):
    assert cli.normalize_mac(value) == expected


@pytest.mark.parametrize("value", ["", "aa:bb:cc", "not-a-mac"])
def test_normalize_mac_rejects_invalid_values(value):
    with pytest.raises(cli.UnifiError, match="invalid MAC address"):
        cli.normalize_mac(value)


def test_choose_network_by_ip_prefers_most_specific_subnet():
    networks = [
        {"_id": "broad", "name": "Broad", "ip_subnet": "192.168.0.0/16"},
        {"_id": "lan", "name": "LAN", "ip_subnet": "192.168.1.1/24"},
        {"_id": "broken", "ip_subnet": "invalid"},
    ]

    selected = cli.choose_network_by_ip(networks, ipaddress.IPv4Address("192.168.1.20"))

    assert selected["_id"] == "lan"


def test_choose_network_by_ip_rejects_ambiguous_subnets():
    networks = [
        {"_id": "one", "name": "One", "ip_subnet": "192.168.1.0/24"},
        {"_id": "two", "name": "Two", "ip_subnet": "192.168.1.1/24"},
    ]

    with pytest.raises(cli.UnifiError, match="multiple networkconf entries"):
        cli.choose_network_by_ip(networks, ipaddress.IPv4Address("192.168.1.20"))


def test_parse_inventory_reservations_normalizes_values():
    reservations = cli.parse_inventory_reservations(
        '[{"hostname":" printer ","mac":"AA-BB-CC-DD-EE-FF","ip":"192.168.1.20"}]'
    )

    assert reservations == [
        cli.ReservationSpec(
            hostname="printer",
            mac="aa:bb:cc:dd:ee:ff",
            fixed_ip=ipaddress.IPv4Address("192.168.1.20"),
        )
    ]


def test_parse_dhcp_range_validates_order():
    dhcp_range = cli.parse_dhcp_range('{"start":"192.168.1.100","end":"192.168.1.200"}')

    assert dhcp_range == cli.DhcpRangeSpec(
        start=ipaddress.IPv4Address("192.168.1.100"),
        end=ipaddress.IPv4Address("192.168.1.200"),
    )

    with pytest.raises(cli.UnifiError, match="is after"):
        cli.parse_dhcp_range('{"start":"192.168.1.200","end":"192.168.1.100"}')


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ('"HOME.ARPA."', ("home.arpa",)),
        ('["home.arpa", "svc.home.arpa."]', ("home.arpa", "svc.home.arpa")),
        ("plain.example", ("plain.example",)),
    ],
)
def test_parse_domain_search_normalizes_json_and_plain_text(raw, expected):
    assert cli.parse_domain_search(raw) == expected


def test_parse_domain_search_rejects_empty_labels():
    with pytest.raises(cli.UnifiError, match="empty label"):
        cli.parse_domain_search('"bad..example"')


def test_parse_dns_records_supports_a_and_cname_records():
    records = dns.parse_records(
        """
        [
          {
            "type": "a_record",
            "domain": "Router.HOME.ARPA.",
            "ttlSeconds": 60,
            "ipv4Address": "192.168.1.1"
          },
          {
            "type": "CNAME_RECORD",
            "domain": "gateway.home.arpa",
            "ttlSeconds": 120,
            "targetDomain": "router.home.arpa."
          }
        ]
        """
    )

    assert records == [
        dns.DnsRecordSpec(
            record_type="A_RECORD",
            domain="router.home.arpa",
            ttl_seconds=60,
            ipv4_address=ipaddress.IPv4Address("192.168.1.1"),
        ),
        dns.DnsRecordSpec(
            record_type="CNAME_RECORD",
            domain="gateway.home.arpa",
            ttl_seconds=120,
            target_domain="router.home.arpa",
        ),
    ]


def test_parse_dns_records_rejects_unsupported_types():
    with pytest.raises(dns.UnifiError, match="unsupported type"):
        dns.parse_records(
            '[{"type":"TXT_RECORD","domain":"home.arpa","ttlSeconds":60}]'
        )


def test_parse_static_routes_normalizes_destination_and_defaults():
    routes = cli.parse_static_routes(
        '[{"name":" private ","destination":"10.1.2.3/8","nextHop":"192.168.1.1"}]'
    )

    assert routes == [
        cli.StaticRouteSpec(
            name="private",
            destination=ipaddress.IPv4Network("10.0.0.0/8"),
            next_hop=ipaddress.IPv4Address("192.168.1.1"),
            distance=1,
        )
    ]


def test_parse_static_routes_rejects_invalid_distance():
    with pytest.raises(cli.UnifiError, match="between 1 and 255"):
        cli.parse_static_routes(
            '[{"name":"private","destination":"10.0.0.0/8",'
            '"nextHop":"192.168.1.1","distance":0}]'
        )


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("192.168.1.10", "192.168.1.10"),
        ("Netboot.HOME.ARPA.", "netboot.home.arpa"),
    ],
)
def test_normalize_tftp_server(value, expected):
    assert cli.normalize_tftp_server(value) == expected


def test_choose_site_matches_any_supported_identifier():
    sites = [
        {"id": "site-id", "internalReference": "default", "name": "Default"},
        {"id": "other-id", "internalReference": "other", "name": "Other"},
    ]

    assert dns.choose_site(sites, "default")["id"] == "site-id"
    assert dns.choose_site(sites, "Other")["id"] == "other-id"
