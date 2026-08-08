{
  config,
  hostInventory,
  lib,
  ...
}:
let
  service = hostInventory.servicesById.home;
  isOwner = service.owner == config.networking.hostName;
  serviceUrl = "https://${service.internalEndpointName}.${hostInventory.site.lan.domain}";
in
{
  config = lib.mkIf isOwner {
    services.home-assistant = {
      configWritable = false;
      lovelaceConfigWritable = false;

      config = {
        default_config = { };

        homeassistant = {
          name = "Home";
          country = hostInventory.regional.countryCode;
          currency = hostInventory.regional.currencyCode;
          internal_url = serviceUrl;
          unit_system = "us_customary";
          time_zone = config.time.timeZone;
        };

        http = {
          server_host = "127.0.0.1";
          server_port = 8123;
          use_x_forwarded_for = true;
          trusted_proxies = [
            "127.0.0.1"
            "::1"
          ];
        };

        prometheus = {
          namespace = "homeassistant";
          # The application listener is loopback-only. Prometheus reaches this
          # endpoint exclusively through the mTLS proxy.
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
  };
}
