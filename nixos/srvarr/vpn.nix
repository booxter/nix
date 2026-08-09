{
  facts,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  namespace = "wg";
in
{
  imports = [
    (import ./update-dynamic-ip.nix {
      inherit
        lib
        namespace
        srvarrPkgs
        utils
        ;
    })
  ];

  host.vpn.namespaces.${namespace} = {
    accessibleFrom = [
      "127.0.0.1"
      facts.site.lan.cidr
      "10.0.0.0/8"
    ];
    bridgeAddress = "192.168.50.5";
    enable = true;
    namespaceAddress = "192.168.50.1";
    wireguardConfigFile = "/data/.secret/vpn/wg.conf";
  };
}
