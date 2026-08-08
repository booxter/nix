{
  config,
  hostInventory,
  ...
}:
let
  backup = hostInventory.backups;
  backupClient = backup.clients.${config.networking.hostName};
  stepStateDir = "/var/lib/step-ca";
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

  host.backups.jobs.beast = {
    title = "Restic To Beast";
    paths = [ stepStateDir ];
    timerConfig = {
      OnCalendar = "04:45";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
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
