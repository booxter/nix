{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  hostname = config.networking.hostName;
  realmName = config.host.realm;
  realm = hostInventory.realms.${realmName};
  observability = realm.services.observability or null;
  alertmanagerPolicy = if observability == null then null else observability.alertmanager or null;
  watchdogHosts = if alertmanagerPolicy == null then [ ] else alertmanagerPolicy.watchdogHosts;
  alertmanagerService = hostInventory.servicesById.alertmanager;
  alertmanagerHost = hostInventory.serviceHost alertmanagerService;
  unknownWatchdogHosts = builtins.filter (
    name: !builtins.hasAttr name hostInventory.nixosHosts
  ) watchdogHosts;
  crossRealmWatchdogHosts = builtins.filter (
    name:
    builtins.hasAttr name hostInventory.nixosHosts
    && hostInventory.nixosHosts.${name}.realm != realmName
  ) watchdogHosts;
  watchdogName = "fana-alertmanager-watchdog";
  watchdogClient = config.host.internalPki.clients.${watchdogName};
  watchdogPackage = pkgs.callPackage ./package {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  alertmanagerReadyUrl = "https://${alertmanagerService.id}.${hostInventory.site.lan.domain}${alertmanagerService.probePath}";
in
{
  options.host.observability.alertmanagerWatchdog.enable = lib.mkOption {
    type = lib.types.bool;
    default = builtins.elem hostname watchdogHosts;
    readOnly = true;
    internal = true;
    description = "Whether this host independently watches the realm Alertmanager.";
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals (alertmanagerPolicy != null) [
        {
          assertion = watchdogHosts != [ ];
          message = "Realm '${realmName}' Alertmanager policy must name at least one watchdog host";
        }
        {
          assertion = builtins.length watchdogHosts == builtins.length (lib.unique watchdogHosts);
          message = "Realm '${realmName}' Alertmanager watchdog hosts must be unique";
        }
        {
          assertion = unknownWatchdogHosts == [ ];
          message =
            "Realm '${realmName}' Alertmanager watchdogs must be managed NixOS hosts: "
            + lib.concatStringsSep ", " unknownWatchdogHosts;
        }
        {
          assertion = crossRealmWatchdogHosts == [ ];
          message =
            "Realm '${realmName}' Alertmanager watchdogs must belong to that realm: "
            + lib.concatStringsSep ", " crossRealmWatchdogHosts;
        }
        {
          assertion = !builtins.elem alertmanagerHost watchdogHosts;
          message = "Realm '${realmName}' Alertmanager server cannot watch itself";
        }
        {
          assertion = (realm.services.internalPki or null) != null;
          message = "Realm '${realmName}' Alertmanager watchdogs require internal PKI";
        }
      ];
    }
    (lib.mkIf config.host.observability.alertmanagerWatchdog.enable {
      host.internalPki.clients.${watchdogName} = {
        enable = true;
        category = "internal";
        materializations.default.restartUnits = [ "${watchdogName}.service" ];
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
        description = "Watch ${alertmanagerHost} Alertmanager readiness and notify Telegram";
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
            (lib.getExe watchdogPackage)
            "--sender"
            hostname
            "--url"
            alertmanagerReadyUrl
            "--ca-file"
            "${config.host.internalPki.rootCaCertificate}"
          ];
          TimeoutStartSec = "45s";
          DynamicUser = true;
          StateDirectory = watchdogName;
          RuntimeDirectory = watchdogName;
          LoadCredential = [
            "telegram-bot-token:${config.sops.secrets.fanaAlertmanagerWatchdogTelegramBotToken.path}"
            "telegram-chat-id:${config.sops.secrets.fanaAlertmanagerWatchdogTelegramChatId.path}"
            "mtls-client-crt:${
              config.sops.secrets.${watchdogClient.materializations.default.certificateSecretName}.path
            }"
            "mtls-client-key:${
              config.sops.secrets.${watchdogClient.materializations.default.keySecretName}.path
            }"
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
    })
  ];
}
