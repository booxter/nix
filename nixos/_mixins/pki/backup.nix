{
  config,
  lib,
  ...
}:
let
  cfg = config.host.internalPki.provider;
  stepStateDir = cfg.stateDirectory;
in
{
  config = lib.mkIf cfg.enable {
    host.backups.jobs.beast = {
      paths = [ stepStateDir ];
    };
  };
}
