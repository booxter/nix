{
  config,
  ...
}:
let
  stateRoot = config.host.srvarrPaths.stateDir;
  pinepodsDatabaseDir = "${stateRoot}/pinepods/postgresql";
  pinepodsBackupDir = "${stateRoot}/pinepods-backup/latest";
  backupPaths = [ stateRoot ];
  seerrConfigDir = "${stateRoot}/seerr";
  seerrBackupDir = "${stateRoot}/seerr-backup/latest";
  houndarrConfigDir = "${stateRoot}/houndarr";
  houndarrBackupDir = "${stateRoot}/houndarr-backup/latest";
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
    pinepodsDatabaseDir
    "${pinepodsDatabaseDir}/**"
  ];
in
{
  host.backups.artifacts.postgresql.pinepods = {
    displayName = "PinePods";
    destinationDir = pinepodsBackupDir;
    includeInBeastBackup = false;
    requiresMountsFor = [ stateRoot ];
  };

  host.backups.artifacts.sqlite.seerr = {
    displayName = "Seerr";
    databasePath = "${seerrConfigDir}/db/db.sqlite3";
    destinationDir = seerrBackupDir;
    includeInBeastBackup = false;
    extraCopies = [
      { source = "${seerrConfigDir}/settings.json"; }
    ];
  };

  # Houndarr has no native backup format. Its documented complete state is the
  # SQLite database plus the Fernet master key used to decrypt stored Arr API
  # keys, so stage an online-consistent database copy and its matching key.
  host.backups.artifacts.sqlite.houndarr = {
    displayName = "Houndarr";
    databasePath = "${houndarrConfigDir}/houndarr.db";
    destinationDir = houndarrBackupDir;
    includeInBeastBackup = false;
    extraCopies = [
      {
        source = "${houndarrConfigDir}/houndarr.masterkey";
        mode = "0600";
        optional = false;
      }
    ];
  };

  host.backups.beast = {
    enable = true;
    clientName = "srvarr";
    paths = backupPaths;
    exclude = backupExclude;
  };
}
