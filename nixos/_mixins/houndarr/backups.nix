{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.houndarr-database = {
      title = "Houndarr";
      database = {
        type = "sqlite";
        path = "${cfg.stateDir}/houndarr.db";
        stagingDir = "${cfg.stateDir}-backup/latest";
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
}
