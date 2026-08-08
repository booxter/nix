{
  config,
  hostInventory,
  ...
}:
let
  backup = hostInventory.backups;
  backupClient = backup.clients.${config.networking.hostName};
  paperlessBackupDir = "/var/lib/paperless-backup/latest";
  paperlessDataDir = "/var/lib/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessStoragePath = config.host.nfs.mounts.paperless;
  backupPaths = [
    paperlessDataDir
    paperlessGptStateDir
    paperlessStoragePath
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

  };

  host.backups.jobs.beast = {
    title = "Restic To Beast";
    paths = backupPaths;
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
}
