{
  config,
  lib,
  ...
}:
let
  cfg = config.host.home-assistant;
  homeAssistantTools = config.host.home-assistant.internal.tools;
  stateDir = "/var/lib/hass";
  databasePath = "${stateDir}/home-assistant_v2.db";
  homeAssistantSso = config.host.sso.applications.home-assistant;
  bootstrapPasswordSecret = "home-assistant/bootstrap-password";
  baseUrl = cfg.localUrl;
  clientId = "${cfg.localUrl}/";
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
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

    host.backups.sources.home-assistant = {
      title = "Home Assistant";
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
      capture = {
        type = "unit";
        unit.service = "home-assistant-native-backup";
      };
    };
  };
}
