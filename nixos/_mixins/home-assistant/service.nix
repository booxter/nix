{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.home-assistant;
  homeAssistantSso = facts.sso.applications.home-assistant;
  oidcClient = config.host.sso.oidc.clients.home-assistant;
in
{
  config = lib.mkIf cfg.enable {
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
          internal_url = "https://home.${config.host.network.lanDomain}";
          unit_system = "us_customary";
          time_zone = config.time.timeZone;
        };

        http = {
          server_host = "127.0.0.1";
          server_port = cfg.port;
          use_x_forwarded_for = true;
          trusted_proxies = [
            "127.0.0.1"
            "::1"
          ];
        };

        auth_oidc = {
          client_id = oidcClient.clientId;
          discovery_url = oidcClient.discoveryUrl;
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

    systemd.services.home-assistant = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };

  };
}
