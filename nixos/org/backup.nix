{ ... }:
let
  litellmBackupDir = "/var/lib/litellm-backup/latest";
  openWebuiBackupDir = "/var/lib/open-webui-backup/latest";
  openWebuiStateDir = "/var/lib/open-webui";
  paperlessBackupDir = "/var/lib/paperless-backup/latest";
  paperlessDataDir = "/var/lib/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessStoragePath = "/data/paperless";
  searchlessStateDir = "/var/lib/searchless-ngx";
  backupPaths = [
    openWebuiStateDir
    paperlessDataDir
    paperlessGptStateDir
    paperlessStoragePath
    searchlessStateDir
    "/var/lib/vikunja/files"
  ];
  backupExclude = [
    "${openWebuiStateDir}/webui.db"
    "${openWebuiStateDir}/webui.db-*"
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
        databasePath = "${openWebuiStateDir}/webui.db";
        destinationDir = openWebuiBackupDir;
        requiresMountsFor = [ openWebuiStateDir ];
      };

      vikunja = {
        displayName = "Vikunja";
        databasePath = "/var/lib/vikunja/vikunja.db";
        destinationDir = "/var/lib/vikunja-backup/latest";
      };
    };
  };

  host.backups.beast = {
    enable = true;
    repoName = "orgvm";
    paths = backupPaths;
    exclude = backupExclude;
  };
}
