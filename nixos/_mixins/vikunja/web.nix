{
  config,
  lib,
  ...
}:
let
  cfg = config.host.vikunja;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.vikunja = {
      upstream = cfg.localUrl;
      public = {
        hostName = cfg.publicHost;
      };
      health.frontend = {
        enable = true;
        path = "";
      };
      metrics.default = {
        enable = true;
        port = cfg.metrics.port;
        upstream = "${cfg.localUrl}/api/v1/metrics";
      };
      auth = {
        oidcRegistration = {
          displayName = "Vikunja";
          originUrls = [ "https://${cfg.publicHost}/auth/openid/sso" ];
          originLanding = "https://${cfg.publicHost}/";
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
        enable = true;
        section = "user";
      };
    };
  };
}
