{ config, lib, ... }:
let
  cfg = config.host.audiobookshelf;
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    host.backups.sources.audiobookshelf = {
      title = "Audiobookshelf";
      capture.type = "scheduled";
      capture.scheduled.outputPaths = [ "${cfg.stateDir}/backups" ];
    };
  };
}
