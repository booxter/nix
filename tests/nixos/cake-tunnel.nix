{ pkgs, ... }:
let
  endpoint = { lib, ... }: {
    # The test framework's acpi_pm clock saturates a vCPU in this workload.
    # Packet scheduling measurements need the paravirtual clock instead.
    boot.kernelParams = lib.mkAfter [ "clocksource=kvm-clock" ];
    environment.etc."cake-tunnel/probes.py".source = ./cake-tunnel/probes.py;
    networking.firewall.enable = false;
    boot.kernelModules = [
      "wireguard"
      "ifb"
    ];
    virtualisation = {
      cores = 2;
      memorySize = 1024;
    };
    environment.systemPackages = [
      pkgs.iperf3
      pkgs.iproute2
      pkgs.wireguard-tools
      (pkgs.python3.withPackages (p: [ p.dnspython ]))
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "cake-tunnel";

  nodes = {
    client = {
      imports = [
        endpoint
        ../../nixos/_mixins/qos
      ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1.ipv4 = {
        addresses = [
          {
            address = "10.10.1.1";
            prefixLength = 24;
          }
        ];
        routes = [
          {
            address = "10.10.2.0";
            prefixLength = 24;
            via = "10.10.1.254";
          }
        ];
      };
      host.qos = {
        cakeIdleDecay.enable = true;
        interfaces.tunnel = {
          device = "eth1";
          limits = {
            upload = {
              queue = "cake";
              rateMbit = 6;
              match = {
                protocol = "udp";
                destinationPort = 1637;
              };
            };
            download = {
              direction = "ingress";
              rateMbit = 80;
              match = {
                protocol = "udp";
                sourcePort = 1637;
              };
            };
          };
        };
      };
    };

    provider = {
      imports = [ endpoint ];
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4 = {
        addresses = [
          {
            address = "10.10.2.1";
            prefixLength = 24;
          }
        ];
        routes = [
          {
            address = "10.10.1.0";
            prefixLength = 24;
            via = "10.10.2.254";
          }
        ];
      };
      services.dnsmasq = {
        enable = true;
        settings = {
          bind-dynamic = true;
          listen-address = "10.77.0.2";
          no-resolv = true;
          address = "/probe.test/10.77.0.2";
        };
      };
    };

    wan = {
      imports = [ endpoint ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.firewall.enable = false;
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      boot.kernelModules = [ "sch_netem" ];
      networking.interfaces = {
        eth1.ipv4.addresses = [
          {
            address = "10.10.1.254";
            prefixLength = 24;
          }
        ];
        eth2.ipv4.addresses = [
          {
            address = "10.10.2.254";
            prefixLength = 24;
          }
        ];
      };
    };
  };

  testScript = builtins.readFile ./cake-tunnel/test.py;
}
