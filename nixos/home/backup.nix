{
  config,
  homeAssistantTools,
  hostInventory,
  lib,
  ...
}:
let
  stateDir = "/var/lib/hass";
  databasePath = "${stateDir}/home-assistant_v2.db";
  homeAssistantPort = 8123;
  homeAssistantSso = hostInventory.sso.applications.home-assistant;
  bootstrapPasswordSecret = "home-assistant/bootstrap-password";
  baseUrl = "http://127.0.0.1:${toString homeAssistantPort}";
  clientId = "http://127.0.0.1:${toString homeAssistantPort}/";
in
{
  systemd.services.home-assistant-native-backup = {
    description = "Create a native Home Assistant backup archive";
    restartIfChanged = false;
    stopIfChanged = false;
    before = [ "restic-backups-beast.service" ];
    requires = [ "home-assistant.service" ];
    after = [ "home-assistant.service" ];
    unitConfig.RequiresMountsFor = [ stateDir ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.escapeShellArgs [
        (lib.getExe homeAssistantTools)
        "backup"
        "--base-url"
        baseUrl
        "--client-id"
        clientId
        "--owner-username"
        homeAssistantSso.bootstrapOwner
        "--password-file"
        config.sops.secrets.${bootstrapPasswordSecret}.path
      ];
      TimeoutStartSec = "2h15m";
    };
  };

  systemd.services.restic-backups-beast = {
    after = [ "home-assistant-native-backup.service" ];
    wants = [ "home-assistant-native-backup.service" ];
    requires = [ "home-assistant-native-backup.service" ];
  };

  host.observability.backupMetrics.jobs.home-assistant-native-backup = {
    service = "home-assistant-native-backup";
    title = "Home Assistant Native Backup";
    phase = "prep";
  };

  host.backups.beast = {
    enable = true;
    clientName = "home";
    paths = [ stateDir ];
    exclude = [
      databasePath
      "${databasePath}-shm"
      "${databasePath}-wal"
      "${stateDir}/home-assistant.log*"
      "${stateDir}/deps"
      "${stateDir}/deps/**"
      "${stateDir}/tts"
      "${stateDir}/tts/**"
    ];
  };
}
