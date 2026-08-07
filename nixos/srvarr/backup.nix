{
  config,
  hostInventory,
  ...
}:
let
  backup = hostInventory.backups;
  backupClient = backup.clients.${config.networking.hostName};
  stateRoot = config.host.srvarrPaths.stateDir;
  mysqlDataDir = "${stateRoot}/mysql";
  pinepodsDatabaseDir = "${stateRoot}/pinepods/postgresql";
  backupPaths = [ stateRoot ];
  rommDatabaseBackupDir = "${stateRoot}/romm-mariadb-backup/latest";
  aurralConfigDir = "${stateRoot}/aurral";
  aurralBackupDir = "${stateRoot}/aurral-backup/latest";
  seerrConfigDir = "${stateRoot}/seerr";
  seerrBackupDir = "${stateRoot}/seerr-backup/latest";
  houndarrConfigDir = "${stateRoot}/houndarr";
  houndarrBackupDir = "${stateRoot}/houndarr-backup/latest";
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
  resticPasswordSecret = "backup/restic/local/password";
  resticSshKeySecret = "backup/restic/local/ssh/privateKey";
in
{
  sops.secrets = {
    ${resticPasswordSecret} = { };
    ${resticSshKeySecret} = {
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  host.backups.artifacts.mariadb.romm = {
    job = "beast";
    displayName = "RomM";
    destinationDir = rommDatabaseBackupDir;
    includeInJob = false;
    requiresMountsFor = [ stateRoot ];
    after = [ "romm-db-init.service" ];
    requires = [ "romm-db-init.service" ];
  };

  host.backups.artifacts.sqlite.aurral = {
    job = "beast";
    displayName = "Aurral";
    databasePath = "${aurralConfigDir}/aurral.db";
    destinationDir = aurralBackupDir;
    includeInJob = false;
  };

  host.backups.artifacts.sqlite.seerr = {
    job = "beast";
    displayName = "Seerr";
    databasePath = "${seerrConfigDir}/db/db.sqlite3";
    destinationDir = seerrBackupDir;
    includeInJob = false;
    extraCopies = [
      { source = "${seerrConfigDir}/settings.json"; }
    ];
  };

  # Houndarr has no native backup format. Its documented complete state is the
  # SQLite database plus the Fernet master key used to decrypt stored Arr API
  # keys, so stage an online-consistent database copy and its matching key.
  host.backups.artifacts.sqlite.houndarr = {
    job = "beast";
    displayName = "Houndarr";
    databasePath = "${houndarrConfigDir}/houndarr.db";
    destinationDir = houndarrBackupDir;
    includeInJob = false;
    extraCopies = [
      {
        source = "${houndarrConfigDir}/houndarr.masterkey";
        mode = "0600";
        optional = false;
      }
    ];
  };

  host.backups.jobs.beast = {
    title = "Restic To Beast";
    paths = backupPaths;
    exclude = backupExclude;
    repository = {
      type = "sftp";
      path = backupClient.repositoryPath;
      passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
      dependencyUnits = [ "sops-install-secrets.service" ];
      sftp = {
        host = backup.server.host;
        user = backupClient.ingestUser;
        identityFile = config.sops.secrets.${resticSshKeySecret}.path;
      };
    };
  };

  # PinePods' downloaded podcast media lives under the separate media root and
  # is intentionally outside this state-only backup.
}
