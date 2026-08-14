{ config, lib, ... }:
let
  cfg = config.host.pinepods;
in
{
  config = lib.mkIf (cfg != null) {
    host.backups.sources.pinepods = {
      title = "PinePods";
      database = {
        type = "postgresql";
        name = "pinepods";
        stagingDir = "/var/lib/pinepods-backup/latest";
      };
    };
  };
}
