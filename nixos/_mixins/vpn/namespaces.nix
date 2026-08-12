{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
in
{
  config = lib.mkIf model.active {
    vpnNamespaces = lib.mapAttrs (namespaceName: namespace: {
      inherit (namespace)
        accessibleFrom
        bridgeAddress
        enable
        namespaceAddress
        wireguardConfigFile
        ;
      openVPNPorts = model.forwardedPorts.${namespaceName} or [ ];
    }) model.cfg.namespaces;
  };
}
