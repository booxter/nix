{
  config,
  ...
}:
let
  stateRoot = config.host.srvarrPaths.stateDir;
  backupPaths = [ stateRoot ];
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
  host.backups.artifacts.sqlite.seerr = {
    displayName = "Seerr";
    databasePath = "${seerrConfigDir}/db/db.sqlite3";
    destinationDir = seerrBackupDir;
    includeInBeastBackup = false;
    extraCopies = [
      { source = "${seerrConfigDir}/settings.json"; }
    ];
  };

  host.backups.beast = {
    enable = true;
    clientName = "srvarr";
    paths = backupPaths;
    exclude = backupExclude;
  };
}
