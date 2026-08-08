{
  config,
  lib,
  ...
}:
let
  cfg = config.services.houndarr;
  backupJob = config.host.backups.destinationJob;
in
{
  config = lib.mkIf cfg.enable {
    host.backups.artifacts.sqlite.houndarr = {
      job = backupJob;
      displayName = "Houndarr";
      databasePath = "${cfg.dataDir}/houndarr.db";
      destinationDir = "${cfg.dataDir}-backup/latest";
      extraCopies = [
        {
          source = "${cfg.dataDir}/houndarr.masterkey";
          mode = "0600";
          optional = false;
        }
      ];
    };
  };
}
