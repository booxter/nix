{ config, ... }:
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

  host.backups.artifacts = {
    postgresql = {
      paperless = {
        job = "beast";
        displayName = "Paperless";
        destinationDir = paperlessBackupDir;
        requiresMountsFor = [ paperlessDataDir ];
      };
    };

    sqlite = {
      vikunja = {
        job = "beast";
        displayName = "Vikunja";
        databasePath = "/var/lib/vikunja/vikunja.db";
        destinationDir = "/var/lib/vikunja-backup/latest";
      };
    };
  };

  host.backups.jobs.beast = {
    title = "Restic To Beast";
    paths = backupPaths;
    repository = {
      type = "sftp";
      # Keep the historical storage namespace so existing snapshots remain in
      # the same local and B2 repositories.
      path = "/volume2/backups/restic-prod/hosts/orgvm";
      passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
      dependencyUnits = [ "sops-install-secrets.service" ];
      sftp = {
        host = "beast";
        user = "restic-org";
        identityFile = config.sops.secrets.${resticSshKeySecret}.path;
      };
    };
  };
}
