{
  config,
  lib,
  ...
}:
let
  cfg = config.host.jellyfin;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.jellyfin = {
      upstream = cfg.localUrl;
      internal = if cfg.web.transport == "internal-mtls" then { } else null;
      public =
        if cfg.web.public.enable then
          {
            inherit (cfg.web.public) hostName;
            inherit (cfg.web) transport;
            directUpstream = lib.mkIf (cfg.web.transport == "direct") cfg.localUrl;
            routes.originalDownloads = {
              location = "~* ^/Items/[^/]+/Download/?$";
              bandwidthLimit = {
                enable = true;
                listenPort = 18096;
                bytesPerSecond = 5 * 1000 * 1000 / 8;
                unlimitedCidrs = [
                  "127.0.0.0/8"
                  "::1"
                  config.host.site.lan.cidr
                  "fe80::/10"
                  "fc00::/7"
                ];
              };
            };
          }
        else
          null;
      health.frontend = {
        enable = true;
        path = "/web/";
      };
      observability.importance = "important";
      dashboard = {
        enable = true;
        section = "user";
      };
    };
  };
}
