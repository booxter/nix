{
  config,
  lib,
  ...
}:
let
  cfg = config.host.watchstate;
  hostName = "watchstate.${config.host.network.lanDomain}";
  sso = config.host.sso.applications.watchstate;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.watchstate = {
      enable = true;
      upstream = cfg.localUrl;
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/v1/api/system/healthcheck";
        };
      };
      presentation = {
        title = "WatchState";
        icon = "sh:watchstate.png";
        dashboard = {
          enable = true;
          section = "media-admin";
        };
      };
      internal.locationExtraConfig = ''
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
      '';
      auth = {
        mode = "oauth2-proxy";
        oauth2ProxyGate = {
          enable = true;
          clientId = "watchstate";
          displayName = "WatchState";
          originLanding = "https://${hostName}/";
          httpAddress = "http://127.0.0.1:4182";
          cookieName = "_watchstate_sso";
          allowedGroups = [ sso.adminGroup ];
          groupClaim = "media_groups";
          whitelistDomains = [ hostName ];
          internalHttpsServiceNames = [ "watchstate" ];
          authRequestHeaders = [ ];
          clearAuthorizationHeader = false;
          probeLocationsByName.watchstate."= /v1/api/system/healthcheck" = {
            proxyPass = cfg.localUrl;
            recommendedProxySettings = true;
            extraConfig = ''
              auth_request off;
            '';
          };
        };
      };
    };
  };
}
