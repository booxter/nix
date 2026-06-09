{
  config,
  hostSpecName,
  lib,
  pkgs,
  ...
}:
let
  catalog = import ./catalog.nix;
  alertmanagerPort = 9093;
  grafanaPort = config.services.grafana.settings.server.http_port;
  validateAlertmanagerConfig = pkgs.writeShellApplication {
    name = "validate-alertmanager-config";
    runtimeInputs = [ config.services.prometheus.alertmanager.package ];
    text = ''
      exec amtool check-config /tmp/alert-manager-substituted.yaml
    '';
  };
in
{
  assertions = [
    {
      assertion = lib.length config.services.prometheus.alertmanagers == 1;
      message = "fanavm monitoring expects a single local Alertmanager target.";
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
    ruleFiles = catalog.prometheus.ruleFiles;
    scrapeConfigs = [
      {
        job_name = "alertmanager";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString alertmanagerPort}" ];
            labels.instance = hostSpecName;
          }
        ];
      }
      {
        job_name = "grafana";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString grafanaPort}" ];
            labels.instance = hostSpecName;
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
    configText = builtins.readFile catalog.alertmanager.configFile;
    environmentFile = config.sops.templates."alertmanager.env".path;
  };

  sops.secrets.grafanaAlertingTelegramBotToken = {
    key = "grafana/alerting/telegram/bot_token";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [ "alertmanager.service" ];
  };
  sops.secrets.grafanaAlertingTelegramChatId = {
    key = "grafana/alerting/telegram/chat_id";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [ "alertmanager.service" ];
  };
  sops.templates."alertmanager.env" = {
    mode = "0400";
    content = ''
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
      ExecStartPre = lib.mkAfter [ (lib.getExe validateAlertmanagerConfig) ];
    };
  };
}
