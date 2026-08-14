{ config, lib, ... }:
let
  cfg = config.host.pinepods;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.pinepods = {
      title = "PinePods";
      database = {
        type = "postgresql";
        name = cfg.databaseName;
        stagingDir = cfg.backups.stagingDir;
      };
    };
  };
}
