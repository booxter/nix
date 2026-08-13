{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.houndarr-database = {
      title = "Houndarr";
      capture = {
        type = "sqlite";
        database = {
          path = "${cfg.stateDir}/houndarr.db";
          destinationDir = "${cfg.stateDir}-backup/latest";
          extraCopies = [
            {
              source = "${cfg.stateDir}/houndarr.masterkey";
              mode = "0600";
              optional = false;
            }
          ];
        };
      };
    };
  };
}
