{ ... }:
let
  stateDir = "/var/lib/hass";
  databasePath = "${stateDir}/home-assistant_v2.db";
in
{
  host.backups.artifacts.sqlite.home-assistant = {
    displayName = "Home Assistant";
    inherit databasePath;
    destinationDir = "/var/lib/home-assistant-backup/latest";
    requiresMountsFor = [ stateDir ];
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
