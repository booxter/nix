{
  config,
  lib,
  ...
}:
let
  cfg = config.host.aurral;
  aurralService = config.host.web.services.aurral;
  browserHost =
    if cfg.publicHostName == null then aurralService.internal.serverName else cfg.publicHostName;
  browserOrigin = "https://${browserHost}";
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
          observability.importance = "important";
          dashboard = {
            enable = true;
            section = "user";
          };
          auth = lib.mkIf cfg.authProxy.enable {
            mode = "oauth2-proxy";
            oauth2ProxyGate = {
              enable = true;
              clientId = "aurral";
              displayName = "Aurral";
              originLanding = "${browserOrigin}/";
              httpAddress = "http://127.0.0.1:4181";
              allowedGroups = cfg.authProxy.allowedGroups;
              groupClaim = "media_groups";
              whitelistDomains = [ browserHost ];
              externalOrigin = if cfg.publicHostName == null then null else browserOrigin;
              internalHttpsServiceNames = [ "aurral" ];
              authCookieVariableName = "aurral_auth_cookie";
              authRequestHeaders = [
                {
                  variableName = "aurral_user";
                  upstreamHeader = "x_auth_request_preferred_username";
                  proxyHeader = "X-Forwarded-User";
                }
                {
                  variableName = "aurral_email";
                  upstreamHeader = "x_auth_request_email";
                  proxyHeader = "X-Forwarded-Email";
                }
                {
                  variableName = "aurral_groups";
                  upstreamHeader = "x_auth_request_groups";
                  proxyHeader = "X-Forwarded-Groups";
                }
              ];
              sessionRefresh = {
                intervalSeconds = 14 * 60;
                lifetimeSeconds = 8 * 60 * 60;
              };
              probeLocationsByName.aurral."= /api/health/live" = {
                proxyPass = "http://127.0.0.1:${toString cfg.port}";
                recommendedProxySettings = true;
                extraConfig = ''
                  auth_request off;
                '';
              };
            };
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

      }
      (lib.mkIf (cfg.publicHostName != null) {
        services.nginx.virtualHosts.${cfg.publicHostName}.locations = imageLocations;
      })
    ]
  );
}
