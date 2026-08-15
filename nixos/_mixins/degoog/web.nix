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
      inherit upstream;
      public = {
        hostName = "goo.${config.host.network.publicDomain}";
      };
      health = {
        frontend = {
          path = "/oauth2/sign_in";
        };
        backend = {
          path = "/readyz";
        };
      };
      observability.importance = "best-effort";
      displayName = "Degoog";
      dashboard = {
        icon = "https://raw.githubusercontent.com/degoog-org/degoog/0.23.0/src/public/images/degoog-logo.png";
        section = "user";
      };
      auth = {
        oauth2ProxyGate = {
          displayName = "Degoog";
          port = oauth2ProxyPort;
          allowedGroups = [ ssoApplication.roles.user ];
          groupClaim = "degoog_groups";
          externalOrigin = service.public.url;
          internalHttpsServiceNames = [ "goo" ];
          authRequestHeaders.X-User = "x_auth_request_preferred_username";
        };
      };
    };
  };
}
