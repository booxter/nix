{
  config,
  ...
}:
let
  backupJob = config.host.backups.destinationJob;
  stateRoot = config.host.srvarrPaths.stateDir;
  backupPaths = [ stateRoot ];
  aurralConfigDir = "${stateRoot}/aurral";
  aurralBackupDir = "${stateRoot}/aurral-backup/latest";
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
  ];
in
{
  host.backups.artifacts.sqlite.aurral = {
    job = backupJob;
    displayName = "Aurral";
    databasePath = "${aurralConfigDir}/aurral.db";
    destinationDir = aurralBackupDir;
    includeInJob = false;
  };

  host.backups.jobs.${backupJob} = {
    paths = backupPaths;
    exclude = backupExclude;
  };
}
