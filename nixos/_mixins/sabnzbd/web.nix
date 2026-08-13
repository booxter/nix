{ config, lib, ... }:
let
  cfg = config.host.sabnzbd;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.sabnzbd = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/__probe/sabnzbd-version";
        };
      };
      displayName = "SABnzbd";
      dashboard = {
        enable = true;
        section = "media-admin";
      };
    };
  };
}
