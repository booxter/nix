{
  config,
  lib,
  ...
}:
let
  cfg = config.host.vikunja;
  mailer = config.host.mailer;
  oidcClient = config.host.sso.oidc.clients.vikunja;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mailer != null;
        message = "Vikunja requires mailer policy for realm '${config.host.realm}'";
      }
    ];

    services.vikunja = lib.mkIf (mailer != null) {
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
          host = mailer.relayHost;
          port = mailer.relayPort;
          username = mailer.address;
          fromemail = mailer.address;
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
