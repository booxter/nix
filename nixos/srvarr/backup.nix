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
  seerrConfigDir = "${stateRoot}/seerr";
  seerrBackupDir = "${stateRoot}/seerr-backup/latest";
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

  host.backups.artifacts.sqlite.seerr = {
    job = backupJob;
    displayName = "Seerr";
    databasePath = "${seerrConfigDir}/db/db.sqlite3";
    destinationDir = seerrBackupDir;
    includeInJob = false;
    extraCopies = [
      { source = "${seerrConfigDir}/settings.json"; }
    ];
  };

  host.backups.jobs.${backupJob} = {
    paths = backupPaths;
    exclude = backupExclude;
  };
}
