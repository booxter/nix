{
  config,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  nullableString = with lib.types; nullOr nonEmptyStr;
  ip = import ../../lib/ipv4.nix { inherit lib; };
  nullableIpv4Address = with lib.types; nullOr (addCheck nonEmptyStr ip.validIpv4);
  nullableIpv4Cidr = with lib.types; nullOr (addCheck nonEmptyStr ip.validCidr);
  peerOptions = {
    address = lib.mkOption {
      type = nullableIpv4Address;
      default = null;
      description = "IPv4 address assigned to this WireGuard peer, without a prefix length.";
    };
    publicKey = lib.mkOption {
      type = nullableString;
      default = null;
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
      hostSpec
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
    server = {
      enable = lib.mkEnableOption "serving a WireGuard network";

      network = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "home";
        description = "Fleet-wide name of the WireGuard network served by this host.";
      };

      interface = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+";
        default = "wg0";
        description = "Network interface used by the WireGuard server.";
      };

      cidr = lib.mkOption {
        type = nullableIpv4Cidr;
        default = null;
        description = "Address range allocated to this WireGuard network.";
      };

      address = lib.mkOption {
        type = nullableIpv4Address;
        default = null;
        description = "Server IPv4 address on the WireGuard network, without a prefix length.";
      };

      listenPort = lib.mkOption {
        type = with lib.types; nullOr port;
        default = null;
        description = "UDP port on which the WireGuard server listens.";
      };

      publicEndpoint = lib.mkOption {
        type = nullableString;
        default = null;
        description = "Public DNS name or address used by clients.";
      };

      publicKey = lib.mkOption {
        type = nullableString;
        default = null;
        description = "Public key of the WireGuard server.";
      };

      clientPolicy = {
        allowedIPs = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "Networks routed through this server by managed clients.";
        };
        dns = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "DNS servers and search domains configured on managed clients.";
        };
        persistentKeepalive = lib.mkOption {
          type = lib.types.ints.positive;
          default = 25;
          description = "Managed client persistent keepalive interval in seconds.";
        };
      };

      dynamicDns = {
        enable = lib.mkEnableOption "dynamic DNS updates for the WireGuard endpoint";
        hostname = lib.mkOption {
          type = nullableString;
          default = null;
          description = "Dynamic DNS hostname updated by the server.";
        };
        username = lib.mkOption {
          type = nullableString;
          default = null;
          description = "Dynamic DNS account used by the server.";
        };
      };

      qos.uploadLimitMbit = lib.mkOption {
        type = with lib.types; nullOr (addCheck number (value: value > 0));
        default = null;
        description = "Optional upload ceiling for WireGuard traffic.";
      };

      externalPeers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { options = peerOptions; });
        default = { };
        description = "WireGuard peers not represented by managed host configurations.";
      };
    };

    client = {
      enable = lib.mkEnableOption "joining a managed WireGuard network";

      network = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "home";
        description = "Fleet-wide name of the WireGuard network joined by this host.";
      };

      interface = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+";
        default = "wg0";
        description = "Network interface used by the WireGuard client.";
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to start the WireGuard client automatically.";
      };

      privateKeySecret = lib.mkOption {
        type = nullableString;
        default = null;
        description = "SOPS key containing the WireGuard client private key.";
      };
    }
    // peerOptions;

    networks = lib.mkOption {
      type = lib.types.attrs;
      default = model.networks;
      readOnly = true;
      internal = true;
      description = "Fleet WireGuard topology assembled from native host role declarations.";
    };
  };
}
