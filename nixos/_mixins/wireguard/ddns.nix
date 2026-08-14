{
  config,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
in
{
  config = lib.mkIf (cfg != null && cfg.dynamicDns != null) {
    host.externalService.ddns = {
      enable = true;
      inherit (cfg.dynamicDns) hostname username;
    };
  };
}
