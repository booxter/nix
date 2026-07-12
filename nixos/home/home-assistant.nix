{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  homeAssistantPort = 8123;
  homeAssistantMetricsPort = 9346;
  homeAssistantService = hostInventory.servicesById.home;
  homeAssistantSso = hostInventory.sso.applications.home-assistant;
  bootstrapOwnerName = homeAssistantSso.bootstrapOwner;
  bootstrapOwner = hostInventory.sso.users.${bootstrapOwnerName};
  bootstrapBaseUrl = "http://127.0.0.1:${toString homeAssistantPort}";
  bootstrapClientId = "http://127.0.0.1:${toString homeAssistantPort}/";
  bootstrapPasswordSecret = "home-assistant/bootstrap-password";
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  oidcClient = oidc.clients.home-assistant;
  # Home Assistant requires a local owner before OIDC can be used. This
  # substituted script completes that bootstrap idempotently without UI edits.
  bootstrapScript = pkgs.replaceVarsWith {
    src = ./home-assistant-bootstrap.sh;
    isExecutable = true;
    replacements = {
      inherit (pkgs) coreutils curl jq;
      baseUrl = lib.escapeShellArg bootstrapBaseUrl;
      clientId = lib.escapeShellArg bootstrapClientId;
      ownerDisplayName = lib.escapeShellArg bootstrapOwner.displayName;
      ownerLanguage = lib.escapeShellArg homeAssistantSso.bootstrapLanguage;
      ownerUsername = lib.escapeShellArg bootstrapOwnerName;
      passwordFile = lib.escapeShellArg config.sops.secrets.${bootstrapPasswordSecret}.path;
    };
  };
in
{
  sops.secrets.${bootstrapPasswordSecret} = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "home-assistant-bootstrap.service" ];
  };

  services.home-assistant = {
    enable = true;
    customComponents = [ pkgs.home-assistant-custom-components.auth_oidc ];
    configWritable = false;
    lovelaceConfigWritable = false;

    config = {
      default_config = { };

      homeassistant = {
        name = "Home";
        country = "US";
        currency = "USD";
        internal_url = "https://home.${hostInventory.site.lan.domain}";
        unit_system = "us_customary";
        time_zone = config.time.timeZone;
      };

      http = {
        server_host = "127.0.0.1";
        server_port = homeAssistantPort;
        use_x_forwarded_for = true;
        trusted_proxies = [
          "127.0.0.1"
          "::1"
        ];
      };

      auth_oidc = {
        client_id = oidcClient.clientId;
        discovery_url = oidc.discoveryUrl oidcClient.clientId;
        display_name = "SSO";
        id_token_signing_alg = "ES256";
        groups_scope = "home_groups";
        additional_scopes = [ "email" ];
        claims = {
          display_name = "name";
          username = "preferred_username";
          groups = "home_groups";
        };
        roles = {
          admin = homeAssistantSso.adminGroup;
          user = homeAssistantSso.userGroup;
        };
        features = {
          automatic_user_linking = true;
          automatic_person_creation = true;
          default_redirect = true;
          force_https = true;
        };
      };

      prometheus = {
        namespace = "homeassistant";
        # The application listener is loopback-only. Prometheus reaches this
        # endpoint exclusively through the mTLS proxy below.
        requires_auth = false;
      };

      recorder = {
        auto_purge = true;
        auto_repack = true;
        purge_keep_days = 30;
      };

      logger = {
        default = "info";
        logs."custom_components.auth_oidc" = "info";
      };

      automation = [ ];
      scene = [ ];
      script = { };
    };

    lovelaceConfig = {
      title = "Home";
      views = [
        {
          title = "Overview";
          path = "overview";
          icon = "mdi:home-assistant";
          cards = [
            {
              type = "markdown";
              title = "Home Assistant";
              content = ''
                Home Assistant is configured declaratively from the Nix fleet repository.

                Device views and automations will be added here as integrations are introduced.
              '';
            }
          ];
        }
      ];
    };
  };

  host.internalHttps.services.home = {
    enable = true;
    upstream = "http://127.0.0.1:${toString homeAssistantPort}";
    locationExtraConfig = ''
      proxy_buffering off;
      proxy_read_timeout 3600s;
    '';
  };

  host.observability.client.prometheusMtlsEndpoints.home-assistant = {
    enable = true;
    port = homeAssistantMetricsPort;
    upstream = "http://127.0.0.1:${toString homeAssistantPort}/api/prometheus";
  };

  systemd.services.home-assistant = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  systemd.services.home-assistant-bootstrap = {
    description = "Bootstrap Home Assistant owner and onboarding state";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "home-assistant.service"
      "sops-install-secrets.service"
    ];
    after = [
      "home-assistant.service"
      "sops-install-secrets.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = bootstrapScript;
      User = "root";
      Group = "root";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  assertions = [
    {
      assertion = homeAssistantService.owner == "home";
      message = "The Home Assistant service catalog entry must be owned by the home host.";
    }
    {
      assertion = builtins.elem homeAssistantSso.adminGroup bootstrapOwner.groups;
      message = "The Home Assistant bootstrap owner must belong to its SSO admin group.";
    }
    {
      assertion = builtins.elem homeAssistantSso.userGroup bootstrapOwner.groups;
      message = "The Home Assistant bootstrap owner must belong to its SSO user group.";
    }
  ];
}
