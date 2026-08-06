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
  resticPasswordSecret = "backup/restic/local/password";
  resticSshKeySecret = "backup/restic/local/ssh/privateKey";
  baseUrl = "http://127.0.0.1:${toString homeAssistantPort}";
  clientId = "http://127.0.0.1:${toString homeAssistantPort}/";
in
{
  systemd.services.home-assistant-native-backup = {
    description = "Create a native Home Assistant backup archive";
    restartIfChanged = false;
    stopIfChanged = false;
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

  sops.secrets = {
    ${resticPasswordSecret} = { };
    ${resticSshKeySecret} = {
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  host.backups.jobs.beast = {
    title = "Restic To Beast";
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
    repository = {
      type = "sftp";
      path = "/volume2/backups/restic-prod/hosts/home";
      passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
      dependencyUnits = [ "sops-install-secrets.service" ];
      sftp = {
        host = "beast";
        user = "restic-home";
        identityFile = config.sops.secrets.${resticSshKeySecret}.path;
      };
    };
    preparations.home-assistant-native-backup = {
      service = "home-assistant-native-backup";
      title = "Home Assistant Native Backup";
    };
  };
}
