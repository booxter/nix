{
  config,
  lib,
  ...
}:
let
  backupJob = config.host.backups.destinationJob;
  cfg = config.host.internalPki.provider;
  stepStateDir = cfg.stateDirectory;
in
{
  config = lib.mkIf cfg.enable {
    host.backups.jobs.${backupJob} = {
      paths = [ stepStateDir ];
    };
  };
}
