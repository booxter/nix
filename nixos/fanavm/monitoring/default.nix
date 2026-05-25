{
  config,
  lib,
  ...
}:
let
  catalog = import ./catalog.nix;
  alertmanagerPort = 9093;
  grafanaPort = config.services.grafana.settings.server.http_port;
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
            labels.instance = config.host.dnsName;
          }
        ];
      }
      {
        job_name = "grafana";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString grafanaPort}" ];
            labels.instance = config.host.dnsName;
          }
        ];
      }
    ];
  };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = alertmanagerPort;
    configText = builtins.readFile catalog.alertmanager.configFile;
  };

  systemd.services.alertmanager = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig.LoadCredential = [
      "telegram-bot-token:${config.sops.secrets.grafanaAlertingTelegramBotToken.path}"
      "telegram-chat-id:${config.sops.secrets.grafanaAlertingTelegramChatId.path}"
    ];
  };
}
