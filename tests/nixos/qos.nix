{ pkgs, ... }:
let
  fixtures = ./qos;
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
        lib,
        pkgs,
        qosModel,
        ...
      }:
      {
        imports = [
          ../../nixos/_mixins/adaptive-upload-policy
          ../../nixos/_mixins/qos
        ];

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

        host.qos.interfaces.adaptive_upload = {
          device = "eth1";
          linkRateMbit = 100;
          limits = {
            cloud-backup = {
              rateMbit = 6;
              match.users = [ "qos-test" ];
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

        host.adaptiveUploadPolicy = {
          fallbackRateMbit = 3;
          source.jellyfin.exporterUrl = "http://127.0.0.1:1/metrics";
          destinations.qos = {
            interface = "eth1";
            limit = "cake-egress";
            match = {
              protocol = "tcp";
              remotePort = 5208;
            };
          };
        };

        host.qos.interfaces.adaptive_upload.limits.cake-egress.rateMbit = 8;

        systemd.services = {
          adaptive-upload-policy.wantedBy = lib.mkForce [ ];
          adaptive-upload-policy-qos.wantedBy = lib.mkForce [ ];
        };

        environment = {
          etc."qos-test/classes.json".source = (pkgs.formats.json { }).generate "qos-test-classes.json" (
            qosModel.classIds.adaptive_upload
          );
          etc."qos-test/config.json".source = qosModel.configFiles.adaptive_upload;
          systemPackages = [
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
    DEVICE = "eth1"
    PEER = ${builtins.toJSON peerAddress}
    SHAPER = "192.168.1.2"
    PEER_IPERF_PORTS = ${builtins.toJSON peerIperfPorts}
    SHAPER_IPERF_PORTS = ${builtins.toJSON shaperIperfPorts}
  ''
  + builtins.readFile "${fixtures}/test.py";
}
