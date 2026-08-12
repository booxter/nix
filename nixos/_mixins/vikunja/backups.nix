{ config, lib, ... }:
let
  cfg = config.host.vikunja;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.vikunja = {
      paths = [ "/var/lib/vikunja/files" ];
      capture = {
        type = "sqlite";
        database = {
          path = "/var/lib/vikunja/vikunja.db";
          destinationDir = "/var/lib/vikunja-backup/latest";
        };
      };
    };
  };
}
