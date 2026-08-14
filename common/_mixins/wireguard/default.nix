{
  config,
  lib,
  outputs,
  ...
}:
let
  ip = import ../../_lib/ipv4.nix { inherit lib; };
  ipv4Address = lib.types.addCheck lib.types.nonEmptyStr ip.validIpv4;
  ipv4Cidr = lib.types.addCheck lib.types.nonEmptyStr ip.validCidr;
  peerOptions = {
    address = lib.mkOption {
      type = ipv4Address;
      description = "IPv4 address assigned to this WireGuard peer, without a prefix length.";
    };
    publicKey = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "WireGuard public key for this peer.";
    };
    extraAllowedIPs = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Additional networks routed to this peer by the server.";
    };
  };
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  imports = [
    ./assertions.nix
    ./client.nix
  ];

  options.host.wireguard = {
    server = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            network = lib.mkOption {
              type = nonEmptyStr;
              description = "Fleet-wide name of the WireGuard network served by this host.";
            };
            interface = lib.mkOption {
              type = strMatching "[A-Za-z0-9_.-]+";
              default = "wg0";
              description = "Network interface used by the WireGuard server.";
            };
            cidr = lib.mkOption {
              type = ipv4Cidr;
              description = "Address range allocated to this WireGuard network.";
            };
            address = lib.mkOption {
              type = ipv4Address;
              description = "Server IPv4 address on the WireGuard network, without a prefix length.";
            };
            listenPort = lib.mkOption {
              type = port;
              description = "UDP port on which the WireGuard server listens.";
            };
            publicEndpoint = lib.mkOption {
              type = nonEmptyStr;
              description = "Public DNS name or address used by clients.";
            };
            publicKey = lib.mkOption {
              type = nonEmptyStr;
              description = "Public key of the WireGuard server.";
            };
            clientPolicy = {
              allowedIPs = lib.mkOption {
                type = nonEmptyListOf nonEmptyStr;
                description = "Networks routed through this server by managed clients.";
              };
              dns = lib.mkOption {
                type = nonEmptyListOf nonEmptyStr;
                description = "DNS servers and search domains configured on managed clients.";
              };
              persistentKeepalive = lib.mkOption {
                type = ints.positive;
                default = 25;
                description = "Managed client persistent keepalive interval in seconds.";
              };
            };
            dynamicDns = lib.mkOption {
              type = nullOr (submodule {
                options = {
                  hostname = lib.mkOption {
                    type = nonEmptyStr;
                    description = "Dynamic DNS hostname updated by the server.";
                  };
                  username = lib.mkOption {
                    type = nonEmptyStr;
                    description = "Dynamic DNS account used by the server.";
                  };
                };
              });
              default = null;
              description = "Dynamic DNS policy for the public WireGuard endpoint.";
            };
            qos.uploadLimitMbit = lib.mkOption {
              type = nullOr (addCheck number (value: value > 0));
              default = null;
              description = "Optional upload ceiling for WireGuard traffic.";
            };
            externalPeers = lib.mkOption {
              type = attrsOf (submodule {
                options = peerOptions;
              });
              default = { };
              description = "WireGuard peers not represented by managed host configurations.";
            };
          };
        });
      default = null;
      description = "WireGuard network served by this host.";
    };

    client = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = peerOptions // {
            network = lib.mkOption {
              type = nonEmptyStr;
              description = "Fleet-wide name of the WireGuard network joined by this host.";
            };
            interface = lib.mkOption {
              type = strMatching "[A-Za-z0-9_.-]+";
              default = "wg0";
              description = "Network interface used by the WireGuard client.";
            };
            autostart = lib.mkOption {
              type = bool;
              default = false;
              description = "Whether to start the WireGuard client automatically.";
            };
            privateKeySecret = lib.mkOption {
              type = nonEmptyStr;
              description = "SOPS key containing the WireGuard client private key.";
            };
          };
        });
      default = null;
      description = "Managed WireGuard network joined by this host.";
    };

    networks = lib.mkOption {
      type = lib.types.attrs;
      default = model.networks;
      readOnly = true;
      internal = true;
      description = "Fleet WireGuard topology assembled from native host role declarations.";
    };
  };
}
