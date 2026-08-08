{
  config,
  hostInventory,
  lib,
  ...
}:
let
  backupJob = config.host.backups.destinationJob;
  outboundMail = hostInventory.realms.${config.host.realm}.services.outboundMail;
  vikunjaService = hostInventory.servicesById.vikunja;
  isOwner = vikunjaService.owner == config.networking.hostName;
  vikunjaMetricsMtlsPort = 9345;
  oidcClient = config.host.sso.oidc.clients.vikunja;
  oidcScopes = config.host.sso.oidc.baseScopes;
  vikunjaSso = hostInventory.sso.applications.vikunja;
  vikunjaOidcProviderKey = "sso";
  vikunjaPort = 3456;
  vikunjaTimezone = config.time.timeZone;
in
{
  config = lib.mkIf isOwner {
    host.sso.oidc.registrations.vikunja = {
      displayName = "Vikunja";
      originUrls = [ "${vikunjaService.url}/auth/openid/sso" ];
      originLanding = "${vikunjaService.url}/";
      allowInsecureClientDisablePkce = true;
      scopeMaps.${vikunjaSso.userGroup} = oidcScopes;
      secret = {
        sopsKey = "vikunja/oidc/client_secret";
        name = "vikunjaOidcClientSecret";
        restartUnits = [ "vikunja.service" ];
      };
    };

    sops.secrets.vikunjaMailerPassword = {
      key = "vikunja/mailer/password";
      restartUnits = [ "vikunja.service" ];
    };

    sops.templates."vikunja-secrets.env" = {
      content = ''
        VIKUNJA_MAILER_PASSWORD=${config.sops.placeholder.vikunjaMailerPassword}
        VIKUNJA_AUTH_OPENID_PROVIDERS_${vikunjaOidcProviderKey}_CLIENTSECRET=${oidcClient.secret.placeholder}
      '';
      restartUnits = [ "vikunja.service" ];
    };

    services.vikunja = {
      enable = true;
      environmentFiles = [ config.sops.templates."vikunja-secrets.env".path ];
      frontendScheme = "https";
      frontendHostname = vikunjaService.publicHost;
      port = vikunjaPort;
      settings = {
        defaultsettings = {
          timezone = vikunjaTimezone;
          week_start = hostInventory.regional.weekStartIso;
        };
        metrics.enabled = true;
        mailer = {
          enabled = true;
          inherit (outboundMail) host port username;
          fromemail = outboundMail.fromAddress;
        };
        service = {
          timezone = vikunjaTimezone;
          enableregistration = false;
        };
        auth = {
          local.enabled = false;
          openid = {
            enabled = true;
            providers.${vikunjaOidcProviderKey} = {
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

    host.internalService.services.vikunja = {
      enable = true;
      upstream = "http://127.0.0.1:${toString vikunjaPort}";
      publicAliases = [ vikunjaService.publicHost ];
      mtls.enable = true;
    };

    host.observability.prometheusEndpoints.vikunja = {
      enable = true;
      port = vikunjaMetricsMtlsPort;
      upstream = "http://127.0.0.1:${toString vikunjaPort}/api/v1/metrics";
    };

    host.backups.artifacts.sqlite.vikunja = {
      job = backupJob;
      displayName = "Vikunja";
      databasePath = "/var/lib/vikunja/vikunja.db";
      destinationDir = "/var/lib/vikunja-backup/latest";
    };

    host.backups.jobs.${backupJob}.paths = [ "/var/lib/vikunja/files" ];
  };
}
