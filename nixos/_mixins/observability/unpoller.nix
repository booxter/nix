{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.unifi.unpoller;
  hostname = config.networking.hostName;
  realmUnifi = hostInventory.realms.${config.host.realm}.services.unifi or null;
  pollerHost = if realmUnifi == null then null else realmUnifi.pollerHost or null;
  pollerHostExists = pollerHost == null || builtins.hasAttr pollerHost hostInventory.nixosHosts;
  isPollerHost = pollerHost == hostname;
in
{
  options.host.unifi.unpoller = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = isPollerHost;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns the realm's UniFi metrics poller to this host.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9130;
      description = "Loopback port on which Unpoller exposes Prometheus metrics.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals (pollerHost != null) [
        {
          assertion = pollerHostExists;
          message = "UniFi poller host '${pollerHost}' must be a managed NixOS host";
        }
        {
          assertion = !pollerHostExists || hostInventory.nixosHosts.${pollerHost}.realm == config.host.realm;
          message = "UniFi poller host '${pollerHost}' must belong to realm '${config.host.realm}'";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.services.prometheus.enable;
          message = "The UniFi poller host must also run the realm's Prometheus server";
        }
      ];

      users.groups.unpoller = { };
      users.users.unpoller = {
        description = "UniFi metrics poller";
        isSystemUser = true;
        group = "unpoller";
      };

      sops.secrets.unpollerUnifiApiKey = {
        key = "unifi/unpoller_api_key";
        restartUnits = [ "unpoller.service" ];
      };

      # The nixpkgs module does not expose upstream's API-key option. Render
      # the complete config at runtime so the key never enters the Nix store.
      sops.templates."unpoller.conf" = {
        owner = "unpoller";
        group = "unpoller";
        mode = "0400";
        file = (pkgs.formats.toml { }).generate "unpoller.conf" {
          poller = {
            quiet = false;
            debug = false;
          };
          prometheus = {
            disable = false;
            http_listen = "127.0.0.1:${toString cfg.port}";
            report_errors = true;
            interval = "60s";
          };
          influxdb.disable = true;
          loki.disable = true;
          datadog.enable = false;
          unifi = {
            dynamic = false;
            defaults = {
              url = realmUnifi.baseUrl;
              api_key = config.sops.placeholder.unpollerUnifiApiKey;
              sites = [ realmUnifi.site ];
              save_sites = true;
              save_dpi = false;
              save_ids = false;
              save_events = false;
              save_alarms = false;
              save_anomalies = false;
              hash_pii = true;
              verify_ssl = true;
              timeout = "60s";
            };
          };
        };
        restartUnits = [ "unpoller.service" ];
      };

      systemd.services.unpoller = {
        description = "Export UniFi Network metrics to Prometheus";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        serviceConfig = {
          ExecStart = "${lib.getExe' pkgs.unpoller "unpoller"} --config ${
            config.sops.templates."unpoller.conf".path
          }";
          User = "unpoller";
          Group = "unpoller";
          Restart = "on-failure";
          RestartSec = "10s";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
        };
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "unpoller";
          scrape_interval = "60s";
          scrape_timeout = "30s";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString cfg.port}" ];
              labels = {
                availability = config.host.availability;
                component = "unpoller";
                instance = "unifi";
                realm = config.host.realm;
                scrape_profile = "network";
              };
            }
          ];
        }
      ];
    })
  ];
}
