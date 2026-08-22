{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.houndarr = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      auth.policy = "media-admin";
    };
  };
}
