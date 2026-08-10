{
  config,
  inputs,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.vpn;
  bridgeAccessPackage = pkgs.callPackage ./pkgs/bridge-access { };

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

  enabledNamespaces = lib.filterAttrs (_: namespace: namespace.enable) cfg.namespaces;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg.clients;
  validClients = lib.filterAttrs (
    _: client: builtins.hasAttr client.namespace enabledNamespaces
  ) enabledClients;
  clientsFor =
    namespaceName: lib.filterAttrs (_: client: client.namespace == namespaceName) validClients;
  bridgeTcpPortsFor =
    namespaceName:
    lib.unique (
      lib.concatMap (client: client.bridgeTcpPorts) (builtins.attrValues (clientsFor namespaceName))
    );
  forwardedPortsFor =
    namespaceName:
    lib.concatMap (client: builtins.attrValues client.forwardedPorts) (
      builtins.attrValues (clientsFor namespaceName)
    );

  bridgeAccessService =
    namespaceName: namespace:
    let
      tcpPorts = bridgeTcpPortsFor namespaceName;
      serviceName = "vpn-${namespaceName}-bridge-access";
      namespaceUnit = "${namespaceName}.service";
      bridgeAccessConfig = (pkgs.formats.json { }).generate "${serviceName}.json" {
        namespace = namespaceName;
        sourceAddress = namespace.bridgeAddress;
        inherit tcpPorts;
      };
      bridgeAccessCommand =
        action:
        utils.escapeSystemdExecArgs [
          (lib.getExe bridgeAccessPackage)
          action
          "--config"
          bridgeAccessConfig
        ];
    in
    lib.nameValuePair serviceName {
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        After = [ namespaceUnit ];
        BindsTo = [ namespaceUnit ];
        PartOf = [ namespaceUnit ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = bridgeAccessCommand "apply";
        ExecStop = bridgeAccessCommand "remove";
      };
    };

  bridgeAccessServices = lib.mapAttrs' bridgeAccessService (
    lib.filterAttrs (name: _: bridgeTcpPortsFor name != [ ]) enabledNamespaces
  );
  clientServices = lib.mapAttrs' (
    _: client:
    let
      namespaceUnit = "${client.namespace}.service";
    in
    lib.nameValuePair client.serviceName {
      unitConfig = {
        After = [ namespaceUnit ];
        BindsTo = [ namespaceUnit ];
        PartOf = [ namespaceUnit ];
      };
      vpnConfinement = {
        enable = true;
        vpnNamespace = client.namespace;
      };
    }
  ) validClients;
in
{
  imports = [
    inputs.vpnconfinement.nixosModules.default
    ./assertions.nix
  ];

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

  config = lib.mkIf (enabledNamespaces != { } || enabledClients != { }) {
    vpnNamespaces = lib.mapAttrs (namespaceName: namespace: {
      inherit (namespace)
        accessibleFrom
        bridgeAddress
        enable
        namespaceAddress
        wireguardConfigFile
        ;
      openVPNPorts = forwardedPortsFor namespaceName;
    }) cfg.namespaces;

    systemd.services = clientServices // bridgeAccessServices;
  };
}
