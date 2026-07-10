{
  config,
  framePkgs,
  hostInventory,
  lib,
  ...
}:
let
  internalPkiRootCaPath = import ../../lib/home-internal-pki-root-ca.nix;
  watchdogName = "fana-alertmanager-watchdog";
  alertmanagerReadyUrl = "https://alertmanager.${hostInventory.site.lan.domain}/-/ready";
in
{
  host.internalHttps.mtlsClients.${watchdogName} = {
    enable = true;
    restartUnits = [ "${watchdogName}.service" ];
  };

  sops.secrets.fanaAlertmanagerWatchdogTelegramBotToken = {
    key = "watchdog/telegram/bot_token";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "${watchdogName}.service" ];
  };
  sops.secrets.fanaAlertmanagerWatchdogTelegramChatId = {
    key = "watchdog/telegram/chat_id";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "${watchdogName}.service" ];
  };

  systemd.services.${watchdogName} = {
    description = "Watch fana Alertmanager readiness and notify Telegram";
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        (lib.getExe framePkgs.fana-alertmanager-watchdog)
        "--url"
        alertmanagerReadyUrl
        "--ca-file"
        (toString internalPkiRootCaPath)
      ];
      TimeoutStartSec = "45s";
      DynamicUser = true;
      StateDirectory = watchdogName;
      RuntimeDirectory = watchdogName;
      LoadCredential = [
        "telegram-bot-token:${config.sops.secrets.fanaAlertmanagerWatchdogTelegramBotToken.path}"
        "telegram-chat-id:${config.sops.secrets.fanaAlertmanagerWatchdogTelegramChatId.path}"
        "mtls-client-crt:${config.sops.secrets."internal-https-client-${watchdogName}-crt".path}"
        "mtls-client-key:${config.sops.secrets."internal-https-client-${watchdogName}-key".path}"
      ];
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictRealtime = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
    };
  };

  systemd.timers.${watchdogName} = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
    };
  };
}
