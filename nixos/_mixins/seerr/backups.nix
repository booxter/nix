{ config, lib, ... }:
let
  cfg = config.host.seerr;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.seerr-database = {
      title = "Seerr";
      capture = {
        type = "sqlite";
        database = {
          path = "${cfg.stateDir}/db/db.sqlite3";
          destinationDir = "${cfg.stateDir}-backup/latest";
          extraCopies = [
            { source = "${cfg.stateDir}/settings.json"; }
          ];
        };
      };
    };
  };
}
