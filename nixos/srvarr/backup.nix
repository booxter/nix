{
  config,
  ...
}:
let
  backupJob = config.host.backups.destinationJob;
  stateRoot = config.host.srvarrPaths.stateDir;
  backupPaths = [ stateRoot ];
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
  ];
in
{
  host.backups.jobs.${backupJob} = {
    paths = backupPaths;
    exclude = backupExclude;
  };
}
