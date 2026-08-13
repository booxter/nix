{ config, lib, ... }:
let
  cfg = config.host.romm;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.romm-database = {
      title = "RomM";
      capture = {
        type = "mariadb";
        database = {
          name = cfg.database.name;
          destinationDir = cfg.backups.stagingDir;
          requiresMountsFor = [ (builtins.dirOf cfg.database.dataDir) ];
          after = [ "romm-db-init.service" ];
          requires = [ "romm-db-init.service" ];
        };
      };
    };
  };
}
