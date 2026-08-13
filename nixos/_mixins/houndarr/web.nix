{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.houndarr = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/api/health";
        };
      };
      dashboard = {
        enable = true;
        icon = "sh:houndarr.png";
        section = "media-admin";
      };
    };
  };
}
