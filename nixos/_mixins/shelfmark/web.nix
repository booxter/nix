{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.shelfmark = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      public = {
        enable = true;
        hostName = cfg.publicHostName;
      };
      health.frontend = {
        enable = true;
        path = "/api/health";
      };
      observability.importance = "important";
      presentation.dashboard = {
        enable = true;
        section = "user";
      };
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host ${cfg.publicHostName};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host ${cfg.publicHostName};
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };
    };
  };
}
