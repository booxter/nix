{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.observability.alertmanager;
  validateAlertmanagerConfig = utils.escapeSystemdExecArgs [
    (lib.getExe' config.services.prometheus.alertmanager.package "amtool")
    "check-config"
    "/tmp/alert-manager-substituted.yaml"
  ];
in
{
  options.host.observability.alertmanager = {
    enable = lib.mkEnableOption "an Alertmanager server";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9093;
      readOnly = true;
      internal = true;
      description = "Loopback Alertmanager HTTP port.";
    };
    endpoint = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = if cfg.enable then config.host.web.services.alertmanager.internal.url else null;
      readOnly = true;
      internal = true;
      description = "Resolved HTTPS endpoint published to Alertmanager clients.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.port;
      checkConfig = false;
      configText = builtins.readFile ../policy/alertmanager/alertmanager.yml;
      environmentFile = config.sops.templates."alertmanager.env".path;
    };

    host.web.services.alertmanager = {
      enable = true;
      upstream = "http://127.0.0.1:${toString cfg.port}";
      internal = {
        path = "= /-/ready";
        proxyWebsockets = false;
        clientAuth = "mtls";
        locationExtraConfig = ''
          access_log off;
        '';
      };
    };

    # Expose only the read-only alerts collection used by the SketchyBar applet.
    # Alertmanager's mutation endpoints remain unavailable on this vhost.
    services.nginx.virtualHosts.internal-https-alertmanager.locations."= /api/v2/alerts" = {
      proxyPass = "http://127.0.0.1:${toString cfg.port}";
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
        ExecStartPre = lib.mkAfter [ validateAlertmanagerConfig ];
      };
    };
  };
}
