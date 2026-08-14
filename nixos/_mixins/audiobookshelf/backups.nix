{ config, lib, ... }:
let
  cfg = config.host.audiobookshelf;
in
{
  config = lib.mkIf (cfg != null && cfg.backups.enable) {
    host.backups.sources.audiobookshelf = {
      title = "Audiobookshelf";
      capture.type = "scheduled";
      capture.scheduled.outputPaths = [ "${cfg.stateDir}/backups" ];
    };
  };
}
