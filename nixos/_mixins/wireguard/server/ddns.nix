{
  config,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
in
{
  config = lib.mkIf (cfg.enable && cfg.dynamicDns.enable) {
    host.externalService.ddns = {
      enable = true;
      inherit (cfg.dynamicDns) hostname username;
    };
  };
}
