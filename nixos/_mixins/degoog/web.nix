{
  config,
  degoogModel,
  lib,
  ...
}:
let
  inherit (degoogModel) cfg ssoApplication;
  service = config.host.web.services.goo;
  upstream = "http://unix:/run/degoog/degoog.sock";
  oauth2ProxyPort = 4183;
in
{
  config = lib.mkIf (cfg.enable && ssoApplication != null) {
    host.site.search.providers.degoog = {
      title = "Degoog";
      aliases = [ "@goo" ];
      endpoint = {
        baseUrl = service.public.url;
        searchPath = "/search";
        queryParameter = "q";
      };
    };

    host.web.services.goo = {
      enable = true;
      inherit upstream;
      public = {
        enable = true;
        hostName = "goo.${config.host.network.publicDomain}";
      };
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/readyz";
        };
      };
      observability.importance = "best-effort";
      displayName = "Degoog";
      dashboard = {
        enable = true;
        icon = "https://raw.githubusercontent.com/degoog-org/degoog/0.23.0/src/public/images/degoog-logo.png";
        section = "user";
      };
      auth = {
        mode = "oauth2-proxy";
        oauth2ProxyGate = {
          enable = true;
          clientId = "goo";
          displayName = "Degoog";
          originLanding = "${service.public.url}/";
          httpAddress = "http://127.0.0.1:${toString oauth2ProxyPort}";
          cookieName = "_goo_sso";
          allowedGroups = builtins.filter (group: group != null) [ ssoApplication.userGroup ];
          groupClaim = "degoog_groups";
          externalOrigin = service.public.url;
          whitelistDomains = [ service.public.hostName ];
          internalHttpsServiceNames = [ "goo" ];
          authCookieVariableName = "goo_auth_cookie";
          authRequestHeaders = [
            {
              variableName = "goo_user";
              upstreamHeader = "x_auth_request_preferred_username";
              proxyHeader = "X-User";
            }
          ];
          probeLocationsByName.goo."= /readyz" = {
            proxyPass = upstream;
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
