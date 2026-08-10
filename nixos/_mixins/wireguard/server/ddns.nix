{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
  network = facts.site.wireguard.${cfg.network};
in
{
  config = lib.mkIf (cfg.network != null) {
    host.externalService.ddns = {
      enable = true;
      inherit (network.gateway.dynamicDns) hostname username;
    };
  };
}
