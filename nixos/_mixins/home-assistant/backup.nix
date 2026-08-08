{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  service = hostInventory.servicesById.home;
  isOwner = service.owner == config.networking.hostName;
  stateDir = config.services.home-assistant.configDir;
  databasePath = "${stateDir}/home-assistant_v2.db";
  port = config.services.home-assistant.config.http.server_port;
  baseUrl = "http://127.0.0.1:${toString port}";
  clientId = "${baseUrl}/";
  passwordSecret = "home-assistant/bootstrap-password";
  backupJob = config.host.backups.destinationJob;
  tools = pkgs.callPackage ./packages/home-assistant-tools { };
in
{
  config = lib.mkIf isOwner {
    assertions = [
      {
        assertion = config.host.backups.client.enable;
        message = "The Home Assistant owner must be a declared backup client.";
      }
    ];

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
          (lib.getExe tools)
          "backup"
          "--base-url"
          baseUrl
          "--client-id"
          clientId
          "--owner-username"
          hostInventory.sso.administrator
          "--password-file"
          config.sops.secrets.${passwordSecret}.path
        ];
        TimeoutStartSec = "2h15m";
      };
    };

    host.backups.jobs.${backupJob} = {
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
      preparations.home-assistant-native-backup = {
        service = "home-assistant-native-backup";
        title = "Home Assistant Native Backup";
      };
    };
  };
}
