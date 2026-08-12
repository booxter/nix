{ lib, ... }:
let
  forwardedPortType = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.port;
        description = "Port allocated by the VPN provider.";
      };

      protocol = lib.mkOption {
        type = lib.types.enum [
          "both"
          "tcp"
          "udp"
        ];
        description = "Transport protocol accepted on the forwarded port.";
      };
    };
  };
in
{
  options.host.vpn = {
    namespaces = lib.mkOption {
      default = { };
      description = "Host-local VPN-backed network namespaces.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "VPN namespace";

            accessibleFrom = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
              description = "Addresses and networks allowed to reach the VPN namespace.";
            };

            bridgeAddress = lib.mkOption {
              type = lib.types.str;
              description = "Host-side address of the namespace bridge.";
            };

            namespaceAddress = lib.mkOption {
              type = lib.types.str;
              description = "Address assigned inside the VPN namespace.";
            };

            wireguardConfigFile = lib.mkOption {
              type = lib.types.str;
              description = "WireGuard configuration used by the namespace.";
            };
          };
        }
      );
    };

    clients = lib.mkOption {
      default = { };
      description = "Services confined to a host-local VPN namespace.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "VPN namespace client" // {
                default = true;
              };

              namespace = lib.mkOption {
                type = lib.types.str;
                description = "VPN namespace used by this service.";
              };

              serviceName = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "systemd service confined to the namespace.";
              };

              bridgeTcpPorts = lib.mkOption {
                type = with lib.types; listOf port;
                default = [ ];
                description = "TCP ports reachable from the host-side bridge.";
              };

              forwardedPorts = lib.mkOption {
                type = lib.types.attrsOf forwardedPortType;
                default = { };
                description = "Named inbound ports allocated by the VPN provider.";
              };
            };
          }
        )
      );
    };
  };
}
