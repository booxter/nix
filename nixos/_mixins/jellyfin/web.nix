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
      enable = true;
      upstream = cfg.localUrl;
      internal.enable = cfg.web.transport == "internal-mtls";
      public = {
        inherit (cfg.web.public) enable hostName;
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
      };
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
