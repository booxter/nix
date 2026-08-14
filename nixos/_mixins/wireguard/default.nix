{ config, lib, ... }:
let
  cfg = config.host.wireguard.server;
in
{
  imports = [
    ./network.nix
    ./observability.nix
    ./qos.nix
  ];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg == null || config.host.network.primaryInterface != null;
          message = "WireGuard server requires a primary network interface.";
        }
      ];
    }
    (lib.mkIf (cfg != null && cfg.dynamicDns != null) {
      host.externalService.ddns = {
        enable = true;
        inherit (cfg.dynamicDns) hostname username;
      };
    })
  ];
}
