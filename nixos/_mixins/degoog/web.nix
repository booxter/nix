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
