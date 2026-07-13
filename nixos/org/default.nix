{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  vikunjaService = hostInventory.servicesById.vikunja;
  vikunjaMetricsMtlsPort = 9345;
  vikunjaOidcClientId = oidc.clients.vikunja.clientId;
  vikunjaOidcProviderKey = "sso";
  vikunjaPort = 3456;
  # Vikunja expects an IANA tz database name here, not a fixed abbreviation.
  vikunjaTimezone = "America/New_York";
in
{
  _module.args.orgPkgs = import ./pkgs pkgs;

  imports = [
    ./ai.nix
    ./backup.nix
    ./llm.nix
    ./paperless.nix
    ./searchless-ngx.nix
    ./searxng.nix
    ./telegram-archive.nix
  ];

  sops.secrets = {
    vikunjaMailerPassword = {
      key = "vikunja/mailer/password";
      restartUnits = [ "vikunja.service" ];
    };
    vikunjaOidcClientSecret = {
      key = "vikunja/oidc/client_secret";
      restartUnits = [ "vikunja.service" ];
    };
  };

  sops.templates."vikunja-secrets.env" = {
    content = ''
      VIKUNJA_MAILER_PASSWORD=${config.sops.placeholder.vikunjaMailerPassword}
      VIKUNJA_AUTH_OPENID_PROVIDERS_${vikunjaOidcProviderKey}_CLIENTSECRET=${config.sops.placeholder.vikunjaOidcClientSecret}
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
            authurl = oidc.openidBaseUrl vikunjaOidcClientId;
            clientid = vikunjaOidcClientId;
            clientsecret = "";
            scope = lib.concatStringsSep " " oidc.baseScopes;
            emailfallback = true;
          };
        };
      };
    };
  };

  host.internalHttps.services.vikunja = {
    enable = true;
    upstream = "http://127.0.0.1:${toString vikunjaPort}";
    publicAliases = [ vikunjaService.publicHost ];
    mtls.enable = true;
  };

  host.observability.client.prometheusMtlsEndpoints.vikunja = {
    enable = true;
    port = vikunjaMetricsMtlsPort;
    upstream = "http://127.0.0.1:${toString vikunjaPort}/api/v1/metrics";
  };
}
