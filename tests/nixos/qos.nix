{ pkgs, ... }:
let
  peerAddress = "192.168.1.1";
  peerIperfPorts = [
    2049
    5201
    5208
    5209
  ];
  peerUdpPorts = [
    1637
    5209
  ];
  shaperIperfPorts = [ 5210 ];
  shaperUdpPorts = [ 5209 ];
in
pkgs.testers.runNixOSTest {
  name = "qos";

  nodes = {
    shaper =
      {
        config,
        pkgs,
        ...
      }:
      {
        imports = [ ../../nixos/_mixins/qos ];

        networking.firewall = {
          enable = true;
          allowedTCPPorts = shaperIperfPorts;
          allowedUDPPorts = shaperUdpPorts;
        };

        users = {
          groups.qos-test = { };
          users.qos-test = {
            isSystemUser = true;
            group = "qos-test";
          };
        };

        host.qos.interfaces.wan = {
          device = "eth1";
          linkRateMbit = 100;
          limits = {
            cloud-backup = {
              rateMbit = 6;
              match.users = [ "qos-test" ];
            };
            cake-egress = {
              rateMbit = 8;
              queue = "cake";
              match = {
                protocol = "tcp";
                destinationPort = 5208;
              };
            };
            gateway-upload = {
              rateMbit = 9;
              queue = "cake";
              match = {
                protocol = "udp";
                sourcePort = 51820;
              };
            };
            nfs = {
              rateMbit = 12;
              match = {
                protocol = "tcp";
                destinationAddress = peerAddress;
                destinationPort = 2049;
              };
            };
            ingress-rate = {
              direction = "ingress";
              rateMbit = 10;
              match = {
                protocol = "tcp";
                destinationPort = 5210;
              };
            };
            wireguard-download = {
              direction = "ingress";
              rateMbit = 10;
              match = {
                protocol = "udp";
                sourcePort = 1637;
              };
            };
            wireguard-upload = {
              rateMbit = 8;
              queue = "cake";
              match = {
                protocol = "udp";
                destinationPort = 1637;
              };
            };
          };
        };

        environment = {
          etc."qos-test/classes.json".source = (pkgs.formats.json { }).generate "qos-test-classes.json" (
            config.host.qos.classIds.wan
          );
          etc."qos-test/config.json".source = config.host.qos.configFiles.wan;
          systemPackages = [
            config.host.qos.package
            pkgs.iperf3
            pkgs.iproute2
            pkgs.nftables
            pkgs.python3
          ];
        };
      };

    peer = {
      networking.firewall = {
        enable = true;
        allowedTCPPorts = peerIperfPorts;
        allowedUDPPorts = peerUdpPorts;
      };
      environment.systemPackages = [
        pkgs.iperf3
        pkgs.python3
      ];
    };
  };

  testScript = ''
    import json
    import shlex


    DEVICE = "eth1"
    PEER = "${peerAddress}"
    SHAPER = "192.168.1.2"
    PEER_IPERF_PORTS = ${builtins.toJSON peerIperfPorts}
    SHAPER_IPERF_PORTS = ${builtins.toJSON shaperIperfPorts}
    UDP_SENDER = """
    import socket
    import sys

    target, destination_port, source_port, count = sys.argv[1:]
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if int(source_port) != 0:
        sender.bind(("", int(source_port)))
    for _ in range(int(count)):
        sender.sendto(b"x" * 1200, (target, int(destination_port)))
    """


    def command(arguments):
        return " ".join(shlex.quote(str(argument)) for argument in arguments)


    def json_command(machine, arguments):
        return json.loads(machine.succeed(command(arguments)))


    def tc_objects(kind, device):
        return json_command(shaper, ["tc", "-j", "-s", kind, "show", "dev", device])


    def tc_object(kind, device, field, value):
        matches = [
            item
            for item in tc_objects(kind, device)
            if item.get(field, "").lower() == value.lower()
        ]
        for item in matches:
            if "options" in item:
                return item
        if matches:
            return matches[0]
        raise AssertionError(f"{kind} object with {field}={value} not found on {device}")


    def packets(item):
        return int(item.get("packets", item.get("stats", {}).get("packets", 0)))


    def class_packets(name):
        return packets(tc_object("class", DEVICE, "handle", CLASS_IDS[name]))


    def ifb_packets(name):
        return packets(tc_object("qdisc", IFBS[name], "kind", "cake"))


    def assert_counter_increases(label, read_counter, generate_traffic):
        before = read_counter()
        generate_traffic()
        after = read_counter()
        if after <= before:
            filters = {
                parent: json_command(
                    shaper,
                    ["tc", "-j", "-s", "filter", "show", "dev", DEVICE, "parent", parent],
                )
                for parent in ("1:", "ffff:")
            }
            raise AssertionError(
                f"{label} counter did not increase: {before} -> {after}; "
                f"filters={filters}"
            )


    def start_iperf_servers(machine, ports):
        for port in ports:
            machine.succeed(command(["iperf3", "--server", "--daemon", "--port", port]))
            machine.wait_for_open_port(port)


    def iperf_rate(machine, target, port, *, user=None, seconds=3):
        arguments = [
            "iperf3",
            "--client", target,
            "--port", port,
            "--time", seconds,
            "--json",
        ]
        if user is not None:
            arguments = ["runuser", "--user", user, "--"] + arguments
        result = json_command(machine, arguments)
        summary = result["end"]["sum_sent"]
        return float(summary["bits_per_second"]) / 1_000_000


    def send_udp(machine, target, destination_port, *, source_port=0, count=64):
        machine.succeed(command([
            "python3", "-c", UDP_SENDER,
            target, destination_port, source_port, count,
        ]))


    def assert_limited(label, measured_mbit, configured_mbit):
        lower = configured_mbit * 0.45
        upper = configured_mbit * 1.40
        assert lower <= measured_mbit <= upper, (
            f"{label}: expected {lower:.1f}..{upper:.1f} Mbit/s, "
            f"measured {measured_mbit:.1f} Mbit/s"
        )


    def set_rate(name, rate_mbit):
        shaper.succeed(command([
            "qosctl",
            "--config", "/etc/qos-test/config.json",
            "--limit", name,
            "--rate-mbit", rate_mbit,
            "set-rate",
        ]))


    start_all()
    shaper.wait_for_unit("qos-wan.service")
    shaper.wait_for_unit("multi-user.target")
    peer.wait_for_unit("multi-user.target")
    start_iperf_servers(peer, PEER_IPERF_PORTS)
    start_iperf_servers(shaper, SHAPER_IPERF_PORTS)
    CLASS_IDS = json_command(shaper, ["cat", "/etc/qos-test/classes.json"])
    qos_config = json_command(shaper, ["cat", "/etc/qos-test/config.json"])
    IFBS = {
        limit["name"]: limit["ifbInterface"]
        for limit in qos_config["limits"]
        if limit["direction"] == "ingress"
    }

    with subtest("service creates the complete topology"):
        shaper.succeed(command(["nft", "list", "table", "inet", "qos_wan"]))
        assert tc_object("qdisc", DEVICE, "kind", "htb")
        assert tc_object("qdisc", DEVICE, "kind", "ingress")
        for ifb in IFBS.values():
            shaper.succeed(command(["ip", "link", "show", "dev", ifb]))
            assert tc_object("qdisc", ifb, "kind", "cake")
        for class_id in CLASS_IDS.values():
            assert tc_object("class", DEVICE, "handle", class_id)
        leaf_kinds = {item["kind"] for item in tc_objects("qdisc", DEVICE)}
        assert {"cake", "fq_codel", "htb", "ingress"} <= leaf_kinds, leaf_kinds

    rates = {}
    with subtest("packet and user matches select their own classes"):
        assert_counter_increases(
            "gateway source port",
            lambda: class_packets("gateway-upload"),
            lambda: send_udp(shaper, PEER, 5209, source_port=51820),
        )
        assert_counter_increases(
            "WireGuard destination port",
            lambda: class_packets("wireguard-upload"),
            lambda: send_udp(shaper, PEER, 1637),
        )
        assert_counter_increases(
            "CAKE egress",
            lambda: class_packets("cake-egress"),
            lambda: rates.setdefault("cake-egress", iperf_rate(shaper, PEER, 5208)),
        )
        assert_counter_increases(
            "NFS destination",
            lambda: class_packets("nfs"),
            lambda: rates.setdefault("nfs", iperf_rate(shaper, PEER, 2049)),
        )
        assert_counter_increases(
            "backup user",
            lambda: class_packets("cloud-backup"),
            lambda: rates.setdefault(
                "cloud-backup",
                iperf_rate(shaper, PEER, 5201, user="qos-test"),
            ),
        )
        assert_counter_increases(
            "ingress CAKE",
            lambda: ifb_packets("ingress-rate"),
            lambda: rates.setdefault("ingress-rate", iperf_rate(peer, SHAPER, 5210)),
        )
        assert_counter_increases(
            "WireGuard ingress source port",
            lambda: ifb_packets("wireguard-download"),
            lambda: send_udp(peer, SHAPER, 5209, source_port=1637),
        )

    with subtest("configured rates constrain representative traffic"):
        assert_limited("CAKE egress", rates["cake-egress"], 8)
        assert_limited("NFS", rates["nfs"], 12)
        assert_limited("cloud backup", rates["cloud-backup"], 6)
        assert_limited("CAKE ingress", rates["ingress-rate"], 10)
        unclassified = iperf_rate(shaper, PEER, 5209, seconds=2)
        assert unclassified > max(rates.values()) * 2, (
            f"unclassified traffic was not clearly faster: {unclassified:.1f} Mbit/s"
        )

    with subtest("runtime update changes the named CAKE limit"):
        set_rate("cake-egress", 3)
        assert_limited("updated CAKE egress", iperf_rate(shaper, PEER, 5208), 3)

    with subtest("restart restores declarative topology"):
        shaper.succeed("systemctl restart qos-wan.service")
        assert_limited("restored CAKE egress", iperf_rate(shaper, PEER, 5208), 8)
        for ifb in IFBS.values():
            shaper.succeed(command(["ip", "link", "show", "dev", ifb]))
        shaper.succeed(command(["nft", "list", "table", "inet", "qos_wan"]))

    with subtest("stop cleans up all owned kernel state"):
        shaper.succeed("systemctl stop qos-wan.service")
        for ifb in IFBS.values():
            shaper.fail(command(["ip", "link", "show", "dev", ifb]))
        shaper.fail(command(["nft", "list", "table", "inet", "qos_wan"]))
        assert not tc_objects("class", DEVICE)
        remaining_qdiscs = {item["kind"] for item in tc_objects("qdisc", DEVICE)}
        assert "htb" not in remaining_qdiscs, remaining_qdiscs
        assert "ingress" not in remaining_qdiscs, remaining_qdiscs
        shaper.succeed("systemctl start qos-wan.service")
        shaper.wait_for_unit("qos-wan.service")
  '';
}
