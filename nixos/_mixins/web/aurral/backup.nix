{
  config,
  lib,
  ...
}:
let
  cfg = config.services.aurral;
in
{
  config = lib.mkIf cfg.enable {
    host.backups.artifacts.sqlite.aurral = {
      job = config.host.backups.destinationJob;
      displayName = "Aurral";
      databasePath = "${cfg.dataDir}/aurral.db";
      destinationDir = "${cfg.dataDir}-backup/latest";
    };
  };
}
