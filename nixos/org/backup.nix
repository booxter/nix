let
  degoogStateDir = "/var/lib/degoog";
  litellmBackupDir = "/var/lib/litellm-backup/latest";
  paperlessBackupDir = "/var/lib/paperless-backup/latest";
  paperlessDataDir = "/var/lib/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessStoragePath = "/data/paperless";
  triliumStateDir = "/var/lib/trilium";
  backupPaths = [
    degoogStateDir
    paperlessDataDir
    paperlessGptStateDir
    paperlessStoragePath
    triliumStateDir
    "/var/lib/vikunja/files"
  ];
  backupExclude = [
    "${triliumStateDir}/document.db"
    "${triliumStateDir}/document.db-*"
  ];
in
{
  host.backups.artifacts = {
    postgresql = {
      litellm = {
        displayName = "LiteLLM";
        destinationDir = litellmBackupDir;
      };

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

      trilium = {
        displayName = "Trilium Notes";
        databasePath = "${triliumStateDir}/document.db";
        destinationDir = "/var/lib/trilium-backup/latest";
        requiresMountsFor = [ triliumStateDir ];
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
    exclude = backupExclude;
  };
}
