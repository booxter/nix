{
  lib,
  vpnModel,
  ...
}:
let
  model = vpnModel;
in
{
  config = lib.mkIf model.active {
    vpnNamespaces = lib.mapAttrs (namespaceName: namespace: {
      inherit (namespace)
        accessibleFrom
        bridgeAddress
        namespaceAddress
        wireguardConfigFile
        ;
      enable = true;
      openVPNPorts = model.forwardedPorts.${namespaceName} or [ ];
    }) model.cfg.namespaces;
  };
}
