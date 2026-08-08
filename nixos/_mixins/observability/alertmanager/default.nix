{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.observability.alertmanager;
  hostname = config.networking.hostName;
  alertmanagerService = hostInventory.servicesById.alertmanager;
  grafanaService = hostInventory.servicesById.grafana;
  prometheusService = hostInventory.servicesById.prometheus;
  alertmanagerPort = cfg.port;
  grafanaUrl = "https://${grafanaService.internalEndpointName}.${hostInventory.site.lan.domain}";
  alertmanagerConfigCheck =
    pkgs.runCommand "alertmanager-config-check"
      {
        nativeBuildInputs = [
          config.services.prometheus.alertmanager.package
          pkgs.gettext
        ];
      }
      ''
        export GRAFANA_URL='https://grafana.example'
        export TELEGRAM_CHAT_ID='-1000000000000'
        envsubst < ${./alertmanager.yml} > alertmanager.yml
        amtool check-config alertmanager.yml
        touch "$out"
      '';
  validateAlertmanagerConfig = utils.escapeSystemdExecArgs [
    (lib.getExe' config.services.prometheus.alertmanager.package "amtool")
    "check-config"
    "/tmp/alert-manager-substituted.yaml"
  ];
in
{
  options.host.observability.alertmanager = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname alertmanagerService;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns the Alertmanager service to this host.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9093;
      description = "Loopback port on which Alertmanager listens.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = hostInventory.serviceRunsOn hostname prometheusService;
          message = "Alertmanager currently requires the realm's Prometheus server on the same host";
        }
        {
          assertion = lib.length config.services.prometheus.alertmanagers == 1;
          message = "Prometheus must have exactly one local Alertmanager target";
        }
      ];

      services.prometheus = {
        alertmanagers = [
          {
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString alertmanagerPort}" ];
              }
            ];
          }
        ];
        scrapeConfigs = [
          {
            job_name = "alertmanager";
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString alertmanagerPort}" ];
                labels.instance = hostname;
              }
            ];
          }
        ];
      };

      services.prometheus.alertmanager = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = alertmanagerPort;
        checkConfig = false;
        configText = builtins.readFile ./alertmanager.yml;
        environmentFile = config.sops.templates."alertmanager.env".path;
      };

      host.internalService.services.${alertmanagerService.id} = {
        enable = true;
        upstream = "http://127.0.0.1:${toString alertmanagerPort}";
        path = "= /-/ready";
        proxyWebsockets = false;
        mtls.enable = true;
        locationExtraConfig = ''
          access_log off;
        '';
      };

      # Expose only the read-only alerts collection used by the SketchyBar applet.
      # Alertmanager's mutation endpoints remain unavailable on this vhost.
      services.nginx.virtualHosts.internal-https-alertmanager.locations."= /api/v2/alerts" = {
        proxyPass = "http://127.0.0.1:${toString alertmanagerPort}";
        recommendedProxySettings = true;
        extraConfig = ''
          limit_except GET {
            deny all;
          }
          access_log off;
        '';
      };

      sops.secrets.grafanaAlertingTelegramBotToken = {
        key = "grafana/alerting/telegram/bot_token";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "alertmanager.service" ];
      };
      sops.secrets.grafanaAlertingTelegramChatId = {
        key = "grafana/alerting/telegram/chat_id";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "alertmanager.service" ];
      };
      sops.templates."alertmanager.env" = {
        mode = "0400";
        content = ''
          GRAFANA_URL=${grafanaUrl}
          TELEGRAM_CHAT_ID=${config.sops.placeholder.grafanaAlertingTelegramChatId}
        '';
        restartUnits = [ "alertmanager.service" ];
      };

      systemd.services.alertmanager = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        serviceConfig = {
          LoadCredential = [
            "telegram-bot-token:${config.sops.secrets.grafanaAlertingTelegramBotToken.path}"
          ];
          ExecStartPre = lib.mkAfter [ validateAlertmanagerConfig ];
        };
      };

      system.extraDependencies = [ alertmanagerConfigCheck ];
    })
  ];
}
