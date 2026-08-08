{
  hostInventory,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  srvarrSpec = hostInventory.nixosHosts.srvarr;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  wgBridgeAddress = srvarrSpec.wgNamespace.bridgeAddress;
  wgNamespaceAddress = srvarrSpec.wgNamespace.namespaceAddress;
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgTimerDeps = {
    After = [ "wg.service" ];
  };
in
{
  imports = [
    (import ./update-dynamic-ip.nix {
      inherit
        lib
        srvarrPkgs
        utils
        wgTimerDeps
        wgUnitDepsBase
        ;
    })
    ./wg-bridge-access.nix
  ];

  vpnNamespaces.wg = {
    accessibleFrom = [
      "127.0.0.1"
      hostInventory.site.lan.cidr
      "10.0.0.0/8"
    ];
    bridgeAddress = wgBridgeAddress;
    enable = true;
    namespaceAddress = wgNamespaceAddress;
    wireguardConfigFile = "/data/.secret/vpn/wg.conf";
  };
}
