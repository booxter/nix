{ config, lib, ... }:
let
  cfg = config.host.seerr;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.seerr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
      public = {
        enable = true;
        hostName = cfg.publicHostName;
      };
      health.frontend = {
        enable = true;
        path = "/login";
      };
      observability.importance = "important";
      dashboard = {
        enable = true;
        section = "user";
      };
    };
  };
}
