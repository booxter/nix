{ ... }:
let
  litellmBackupDir = "/var/lib/litellm-backup/latest";
  openWebuiBackupDir = "/var/lib/open-webui-backup/latest";
  openWebuiStateDir = "/var/lib/open-webui";
  openWebuiDataDir = "${openWebuiStateDir}/data";
  openWebuiDatabasePath = "${openWebuiDataDir}/webui.db";
  paperlessBackupDir = "/var/lib/paperless-backup/latest";
  paperlessDataDir = "/var/lib/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessStoragePath = "/data/paperless";
  searchlessStateDir = "/var/lib/searchless-ngx";
  telegramArchiveStateDir = "/var/lib/telegram-archive";
  telegramArchiveBackupDir = "/var/lib/telegram-archive-backup";
  telegramArchiveDatabasePath = "${telegramArchiveStateDir}/backups/telegram_backup.db";
  telegramArchiveSessionPath = "${telegramArchiveStateDir}/session/telegram_archive.session";
  triliumStateDir = "/var/lib/trilium";
  backupPaths = [
    openWebuiStateDir
    paperlessDataDir
    paperlessGptStateDir
    paperlessStoragePath
    searchlessStateDir
    telegramArchiveStateDir
    triliumStateDir
    "/var/lib/vikunja/files"
  ];
  backupExclude = [
    openWebuiDatabasePath
    "${openWebuiDatabasePath}-*"
    telegramArchiveDatabasePath
    "${telegramArchiveDatabasePath}-*"
    telegramArchiveSessionPath
    "${telegramArchiveSessionPath}-*"
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
      open-webui = {
        displayName = "Open WebUI";
        databasePath = openWebuiDatabasePath;
        destinationDir = openWebuiBackupDir;
        requiresMountsFor = [ openWebuiDataDir ];
      };

      vikunja = {
        displayName = "Vikunja";
        databasePath = "/var/lib/vikunja/vikunja.db";
        destinationDir = "/var/lib/vikunja-backup/latest";
      };

      telegram-archive = {
        displayName = "Telegram Archive";
        databasePath = telegramArchiveDatabasePath;
        destinationDir = "${telegramArchiveBackupDir}/database/latest";
        unitConfig.ConditionPathExists = telegramArchiveDatabasePath;
      };

      telegram-archive-session = {
        displayName = "Telegram Archive authenticated session";
        databasePath = telegramArchiveSessionPath;
        destinationDir = "${telegramArchiveBackupDir}/session/latest";
        unitConfig.ConditionPathExists = telegramArchiveSessionPath;
        extraCopies = [
          {
            source = "${telegramArchiveSessionPath}.authenticated";
            mode = "0600";
          }
        ];
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
