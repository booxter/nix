let
  degoogStateDir = "/var/lib/degoog";
  paperlessBackupDir = "/var/lib/paperless-backup/latest";
  paperlessDataDir = "/var/lib/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessStoragePath = "/data/paperless";
  backupPaths = [
    degoogStateDir
    paperlessDataDir
    paperlessGptStateDir
    paperlessStoragePath
    "/var/lib/vikunja/files"
  ];
in
{
  host.backups.artifacts = {
    postgresql = {
      paperless = {
        displayName = "Paperless";
        destinationDir = paperlessBackupDir;
        requiresMountsFor = [ paperlessDataDir ];
      };
    };

    sqlite = {
      vikunja = {
        displayName = "Vikunja";
        databasePath = "/var/lib/vikunja/vikunja.db";
        destinationDir = "/var/lib/vikunja-backup/latest";
      };
    };
  };

  host.backups.beast = {
    enable = true;
    clientName = "org";
    # Keep the historical storage namespace: changing it would create new
    # local and B2 repositories instead of preserving the existing snapshots.
    storageName = "orgvm";
    paths = backupPaths;
  };
}
