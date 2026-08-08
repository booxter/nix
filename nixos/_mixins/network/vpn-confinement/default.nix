{
  config,
  hostInventory,
  inputs,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.vpnConfinement;
  hostname = config.networking.hostName;
  package = pkgs.callPackage ./package { };
  requiredServices = lib.filterAttrs (
    _: service:
    builtins.hasAttr hostname service.instances && service.instances.${hostname} ? vpnConfinement
  ) hostInventory.servicesById;
  requirements = lib.mapAttrs (
    _: service: service.instances.${hostname}.vpnConfinement
  ) requiredServices;
  implementations = cfg.implementations;
  requiredNames = builtins.attrNames requirements;
  implementationNames = builtins.attrNames implementations;
  missingImplementations = lib.subtractLists implementationNames requiredNames;
  unexpectedImplementations = lib.subtractLists requiredNames implementationNames;
  validImplementations = lib.filterAttrs (
    name: _: builtins.hasAttr name requirements
  ) implementations;
  disabledImplementations = lib.filterAttrs (_: implementation: !implementation.serviceEnabled) (
    lib.filterAttrs (name: _: builtins.hasAttr name requirements) implementations
  );
  emptyImplementations = lib.filterAttrs (_: implementation: implementation.systemdUnits == [ ]) (
    lib.filterAttrs (name: _: builtins.hasAttr name requirements) implementations
  );
  confinedUnits = lib.concatMap (
    serviceName:
    let
      requirement = requirements.${serviceName};
      profile = hostInventory.egressVpns.${requirement.profile};
    in
    map (unit: {
      inherit unit;
      namespace = profile.namespace;
    }) validImplementations.${serviceName}.systemdUnits
  ) (builtins.attrNames validImplementations);
  confinedUnitNames = map (entry: entry.unit) confinedUnits;
  activeProfileNames = lib.unique (
    map (requirement: requirement.profile) (builtins.attrValues requirements)
  );
  activeProfiles = lib.genAttrs activeProfileNames (name: hostInventory.egressVpns.${name});
  activeNamespaces = map (profile: profile.namespace) (builtins.attrValues activeProfiles);
  forwardedPortsFor =
    profileName:
    lib.concatMap (
      requirement:
      lib.optional (
        requirement.profile == profileName && requirement ? forwardedPort
      ) requirement.forwardedPort
    ) (builtins.attrValues requirements);
  bridgeTcpPortsFor =
    profileName:
    lib.unique (
      lib.concatMap (
        serviceName:
        lib.optionals (requirements.${serviceName}.profile == profileName) (
          validImplementations.${serviceName}.bridgeTcpPorts
        )
      ) (builtins.attrNames validImplementations)
    );
  profilesWithBridgeAccess = lib.filterAttrs (name: _: bridgeTcpPortsFor name != [ ]) activeProfiles;
  bridgeAccessConfigFor =
    profileName: profile:
    (pkgs.formats.json { }).generate "${profileName}-bridge-access.json" {
      namespace = profile.namespace;
      sourceAddress = profile.bridgeAddress;
      tcpPorts = bridgeTcpPortsFor profileName;
    };
  bridgeAccessCommand =
    profileName: profile: action:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      action
      "--config"
      (bridgeAccessConfigFor profileName profile)
    ];
in
{
  imports = [ inputs.vpnconfinement.nixosModules.default ];

  options.host.vpnConfinement.implementations = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          serviceEnabled = lib.mkOption {
            type = lib.types.bool;
            description = "Whether the inventory service's local implementation is enabled.";
          };

          systemdUnits = lib.mkOption {
            type = with lib.types; listOf str;
            description = "Systemd units that must share the service's VPN namespace.";
          };

          bridgeTcpPorts = lib.mkOption {
            type = with lib.types; listOf port;
            default = [ ];
            description = "TCP ports reachable from the host through the namespace bridge.";
          };
        };
      }
    );
    default = { };
    internal = true;
    description = "Local implementations of inventory-required VPN confinement.";
  };

  config = {
    assertions = [
      {
        assertion = missingImplementations == [ ];
        message = "VPN-required services lack local confinement implementations: ${lib.concatStringsSep ", " missingImplementations}";
      }
      {
        assertion = unexpectedImplementations == [ ];
        message = "Services implement VPN confinement without an inventory requirement: ${lib.concatStringsSep ", " unexpectedImplementations}";
      }
      {
        assertion = disabledImplementations == { };
        message = "Inventory requires VPN-confined services that are disabled locally: ${lib.concatStringsSep ", " (builtins.attrNames disabledImplementations)}";
      }
      {
        assertion = emptyImplementations == { };
        message = "VPN confinement implementations must register at least one systemd unit: ${lib.concatStringsSep ", " (builtins.attrNames emptyImplementations)}";
      }
      {
        assertion = builtins.length confinedUnitNames == builtins.length (lib.unique confinedUnitNames);
        message = "A systemd unit must not implement VPN confinement for multiple services.";
      }
      {
        assertion = builtins.length activeNamespaces == builtins.length (lib.unique activeNamespaces);
        message = "Active egress VPN profiles must use distinct namespace names.";
      }
      {
        assertion = builtins.all (namespace: builtins.stringLength namespace < 8) activeNamespaces;
        message = "VPN namespace names must be shorter than eight characters.";
      }
    ];

    vpnNamespaces = lib.mapAttrs' (
      profileName: profile:
      lib.nameValuePair profile.namespace {
        enable = true;
        inherit (profile)
          accessibleFrom
          bridgeAddress
          namespaceAddress
          wireguardConfigFile
          ;
        openVPNPorts = forwardedPortsFor profileName;
      }
    ) activeProfiles;

    systemd.services = lib.mkMerge [
      (lib.mkMerge (
        map (entry: {
          ${entry.unit} = {
            partOf = [ "${entry.namespace}.service" ];
            vpnConfinement = {
              enable = true;
              vpnNamespace = entry.namespace;
            };
          };
        }) confinedUnits
      ))
      (lib.mapAttrs' (
        profileName: profile:
        lib.nameValuePair "${profile.namespace}-bridge-access" {
          description = "Allow host access to ${profileName} VPN namespace services";
          wantedBy = [ "multi-user.target" ];
          after = [ "${profile.namespace}.service" ];
          bindsTo = [ "${profile.namespace}.service" ];
          partOf = [ "${profile.namespace}.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = bridgeAccessCommand profileName profile "apply";
            ExecStop = bridgeAccessCommand profileName profile "remove";
          };
        }
      ) profilesWithBridgeAccess)
    ];
  };
}
