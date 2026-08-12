{
  config,
  lib,
  ...
}:
let
  cfg = config.host.vikunja;
  oidcClient = config.host.sso.oidc.clients.vikunja;
in
{
  config = lib.mkIf cfg.enable {
    services.vikunja = {
      enable = true;
      environmentFiles = [ config.sops.templates."vikunja-secrets.env".path ];
      frontendScheme = "https";
      frontendHostname = cfg.publicHost;
      port = cfg.port;
      settings = {
        defaultsettings = {
          timezone = config.host.site.timeZone;
          week_start = 1;
        };
        metrics.enabled = true;
        mailer = {
          enabled = true;
          host = "smtp.gmail.com";
          port = 587;
          username = "ihar.hrachyshka@gmail.com";
          fromemail = "ihar.hrachyshka@gmail.com";
        };
        service = {
          timezone = config.host.site.timeZone;
          enableregistration = false;
        };
        auth = {
          local.enabled = false;
          openid = {
            enabled = true;
            providers.sso = {
              name = "SSO";
              authurl = oidcClient.issuerUrl;
              clientid = oidcClient.clientId;
              clientsecret = "";
              scope = lib.concatStringsSep " " oidcClient.baseScopes;
              emailfallback = true;
            };
          };
        };
      };
    };
  };
}
