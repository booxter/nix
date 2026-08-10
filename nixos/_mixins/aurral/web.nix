{
  config,
  lib,
  ...
}:
let
  cfg = config.host.aurral;
  cacheZone = "aurral_images";
  cacheLocation = {
    proxyPass = "http://127.0.0.1:${toString cfg.port}";
    recommendedProxySettings = true;
    extraConfig = ''
      proxy_cache ${cacheZone};
      proxy_cache_background_update on;
      proxy_cache_lock on;
      proxy_cache_revalidate on;
      proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    '';
  };
  imageLocations = {
    "^~ /api/image-proxy/" = cacheLocation;
  };
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        host.web.services.aurral = {
          enable = true;
          upstream = "http://127.0.0.1:${toString cfg.port}";
          public = {
            enable = cfg.publicHostName != null;
            hostName = cfg.publicHostName;
            locationExtraConfig = ''
              proxy_set_header X-Forwarded-For $remote_addr;
            '';
          };
          health = {
            frontend = {
              enable = cfg.publicHostName != null;
              path = "/oauth2/sign_in";
            };
            backend = {
              enable = true;
              path = "/api/health/live";
            };
          };
          presentation.dashboard = {
            enable = true;
            category = "user";
          };
        };

        services.nginx.proxyCachePath.aurral-images = {
          enable = true;
          keysZoneName = cacheZone;
          keysZoneSize = "1m";
          inactive = "7d";
          maxSize = "256m";
        };

        systemd.tmpfiles.rules = [
          "d /var/cache/nginx/aurral-images 0750 nginx nginx - -"
        ];

        services.nginx.virtualHosts."internal-https-aurral".locations = imageLocations;

        services.nginx.virtualHosts."internal-https-aurral-probe".locations."= /api/health/live" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          recommendedProxySettings = true;
          extraConfig = ''
            auth_request off;
          '';
        };
      }
      (lib.mkIf (cfg.publicHostName != null) {
        services.nginx.virtualHosts.${cfg.publicHostName}.locations = imageLocations;
      })
    ]
  );
}
