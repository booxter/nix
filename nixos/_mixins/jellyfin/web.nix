{
  config,
  lib,
  ...
}:
let
  cfg = config.host.jellyfin;
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.jellyfin = {
      upstream = "http://127.0.0.1:8096";
      internal = null;
      public = {
        hostName = "jf.${config.host.network.publicDomain}";
        routes.originalDownloads = {
          location = "~* ^/Items/[^/]+/Download/?$";
          bandwidthLimit = {
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
        path = "/web/";
      };
      observability.importance = "important";
      dashboard = {
        section = "user";
      };
    };
  };
}
