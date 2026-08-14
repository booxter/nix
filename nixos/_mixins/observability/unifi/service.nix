{
  config,
  lib,
  pkgs,
  ...
}:
let
  serverEnabled = config.host.observability.server != null;
  controller = config.host.site.lan.ipController;
  metricsPort = 9130;
in
{
  config = lib.mkIf serverEnabled {
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

    # The nixpkgs module does not yet expose upstream's API-key option. Render
    # the complete config at runtime so the key never enters the Nix store.
    sops.templates."unpoller.conf" = {
      owner = "unpoller";
      group = "unpoller";
      mode = "0400";
      content = ''
        [poller]
        quiet = false
        debug = false

        [prometheus]
        disable = false
        http_listen = "127.0.0.1:${toString metricsPort}"
        report_errors = true
        interval = "60s"

        [influxdb]
        disable = true

        [loki]
        disable = true

        [datadog]
        enable = false

        [unifi]
        dynamic = false

        [unifi.defaults]
        url = "${toString (controller.endpoint or null)}"
        api_key = "${config.sops.placeholder.unpollerUnifiApiKey}"
        sites = ["${toString (controller.site or null)}"]
        save_sites = true
        save_dpi = false
        save_ids = false
        save_events = false
        save_alarms = false
        save_anomalies = false
        hash_pii = true
        verify_ssl = true
        timeout = "60s"
      '';
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
            targets = [ "127.0.0.1:${toString metricsPort}" ];
            labels = {
              component = "unpoller";
              instance = "unifi";
              scrape_profile = "network";
            };
          }
        ];
      }
    ];
  };
}
