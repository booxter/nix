{
  config,
  lib,
  vikunjaModel,
  ...
}:
let
  inherit (vikunjaModel)
    cfg
    localUrl
    metricsPort
    publicHost
    ;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.vikunja = {
      upstream = localUrl;
      public = {
        hostName = publicHost;
      };
      health.frontend = {
        path = "";
      };
      metrics.default = {
        port = metricsPort;
        upstream = "${localUrl}/api/v1/metrics";
      };
      auth = {
        oidcRegistration = {
          displayName = "Vikunja";
          originUrls = [ "https://${publicHost}/auth/openid/sso" ];
          originLanding = "https://${publicHost}/";
          allowInsecureClientDisablePkce = true;
          scopeMaps."vikunja-users" = oidcScopes;
          secret = {
            sopsKey = "vikunja/oidc/client_secret";
            name = "vikunjaOidcClientSecret";
            restartUnits = [ "vikunja.service" ];
          };
        };
      };
      displayName = "Vikunja";
      dashboard = {
        section = "user";
      };
    };
  };
}
