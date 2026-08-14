{ config, lib, ... }:
let
  cfg = config.host.vikunja;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.vikunja = {
      paths = [ "/var/lib/vikunja/files" ];
      database = {
        type = "sqlite";
        path = "/var/lib/vikunja/vikunja.db";
        stagingDir = "/var/lib/vikunja-backup/latest";
      };
    };
  };
}
