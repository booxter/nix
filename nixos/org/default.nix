{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  vikunjaPublicHost = "vi.${facts.site.public.domain}";
  vikunjaMetricsMtlsPort = 9345;
  oidcClient = config.host.sso.oidc.clients.vikunja;
  oidcScopes = config.host.sso.oidc.baseScopes;
  vikunjaOidcProviderKey = "sso";
  vikunjaPort = 3456;
  # Vikunja expects an IANA tz database name here, not a fixed abbreviation.
  vikunjaTimezone = "America/New_York";
in
{
  system.stateVersion = "25.11";

  _module.args.orgPkgs = import ./pkgs pkgs;

  imports = [
    ./degoog.nix
    ./paperless.nix
  ];

  host.backups.sources.vikunja = {
    paths = [ "/var/lib/vikunja/files" ];
    capture = {
      type = "sqlite";
      database = {
        path = "/var/lib/vikunja/vikunja.db";
        destinationDir = "/var/lib/vikunja-backup/latest";
      };
    };
  };

  sops.secrets = {
    vikunjaMailerPassword = {
      key = "vikunja/mailer/password";
      restartUnits = [ "vikunja.service" ];
    };
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
    frontendHostname = vikunjaPublicHost;
    port = vikunjaPort;
    settings = {
      defaultsettings = {
        timezone = vikunjaTimezone;
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

  host.web.services.vikunja = {
    enable = true;
    upstream = "http://127.0.0.1:${toString vikunjaPort}";
    public = {
      enable = true;
      hostName = vikunjaPublicHost;
    };
    health.frontend = {
      enable = true;
      path = "";
    };
    metrics.default = {
      enable = true;
      port = vikunjaMetricsMtlsPort;
      upstream = "http://127.0.0.1:${toString vikunjaPort}/api/v1/metrics";
    };
    auth = {
      mode = "oidc";
      oidcRegistration = {
        displayName = "Vikunja";
        originUrls = [ "https://${vikunjaPublicHost}/auth/openid/sso" ];
        originLanding = "https://${vikunjaPublicHost}/";
        allowInsecureClientDisablePkce = true;
        scopeMaps."vikunja-users" = oidcScopes;
        secret = {
          sopsKey = "vikunja/oidc/client_secret";
          name = "vikunjaOidcClientSecret";
          restartUnits = [ "vikunja.service" ];
        };
      };
    };
    presentation = {
      title = "Vikunja";
      dashboard = {
        enable = true;
        category = "user";
      };
    };
  };
}
