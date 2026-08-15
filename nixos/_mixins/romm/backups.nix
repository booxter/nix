{ config, lib, ... }:
let
  cfg = config.host.romm;
in
{
  config = lib.mkIf (cfg != null) {
    host.backups.sources.romm-database = {
      title = "RomM";
      database = {
        type = "mariadb";
        name = cfg.database.name;
        stagingDir = cfg.backups.stagingDir;
        requiresMountsFor = [ (builtins.dirOf cfg.database.dataDir) ];
        after = [ "romm-db-init.service" ];
        requires = [ "romm-db-init.service" ];
      };
    };
  };
}
