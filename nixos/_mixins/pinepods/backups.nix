{ config, lib, ... }:
let
  cfg = config.host.pinepods;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.pinepods = {
      title = "PinePods";
      capture = {
        type = "postgresql";
        database = {
          name = cfg.databaseName;
          destinationDir = cfg.backups.stagingDir;
        };
      };
    };
  };
}
