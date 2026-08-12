{ config, lib, ... }:
let
  cfg = config.host.vikunja;
  oidcClient = config.host.sso.oidc.clients.vikunja;
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets.vikunjaMailerPassword = {
      key = "vikunja/mailer/password";
      restartUnits = [ "vikunja.service" ];
    };

    sops.templates."vikunja-secrets.env" = {
      content = ''
        VIKUNJA_MAILER_PASSWORD=${config.sops.placeholder.vikunjaMailerPassword}
        VIKUNJA_AUTH_OPENID_PROVIDERS_sso_CLIENTSECRET=${oidcClient.secret.placeholder}
      '';
      restartUnits = [ "vikunja.service" ];
    };
  };
}
