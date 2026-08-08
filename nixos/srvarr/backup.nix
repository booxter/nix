{
  config,
  ...
}:
let
  backupJob = config.host.backups.destinationJob;
  stateRoot = config.host.srvarrPaths.stateDir;
  mysqlDataDir = "${stateRoot}/mysql";
  pinepodsDatabaseDir = "${stateRoot}/pinepods/postgresql";
  backupPaths = [ stateRoot ];
  rommDatabaseBackupDir = "${stateRoot}/romm-mariadb-backup/latest";
  aurralConfigDir = "${stateRoot}/aurral";
  aurralBackupDir = "${stateRoot}/aurral-backup/latest";
  seerrConfigDir = "${stateRoot}/seerr";
  seerrBackupDir = "${stateRoot}/seerr-backup/latest";
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
    mysqlDataDir
    "${mysqlDataDir}/**"
    pinepodsDatabaseDir
    "${pinepodsDatabaseDir}/**"
  ];
in
{
  host.backups.artifacts.mariadb.romm = {
    job = backupJob;
    displayName = "RomM";
    destinationDir = rommDatabaseBackupDir;
    includeInJob = false;
    requiresMountsFor = [ stateRoot ];
    after = [ "romm-db-init.service" ];
    requires = [ "romm-db-init.service" ];
  };

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

  # PinePods' downloaded podcast media lives under the separate media root and
  # is intentionally outside this state-only backup.
}
