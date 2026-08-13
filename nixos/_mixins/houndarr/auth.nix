{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  config = lib.mkIf (cfg.enable && cfg.authProxy.gate != null) {
    host.sso.oauth2ProxyGates.${cfg.authProxy.gate}.internalHttpsServiceNames = lib.mkAfter [
      "houndarr"
    ];
  };
}
