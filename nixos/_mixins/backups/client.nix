{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  backup = hostInventory.realms.${config.host.realm}.services.backups or null;
  isRemoteClient =
    backup != null && builtins.hasAttr hostname backup.clients && hostname != backup.server.localClient;
  client = backup.clients.${hostname};
  jobName = backup.server.host;
  jobTitle = "${lib.toUpper (lib.substring 0 1 jobName)}${
    lib.substring 1 (builtins.stringLength jobName) jobName
  }";
  resticPasswordSecret = "backup/restic/local/password";
  resticSshKeySecret = "backup/restic/local/ssh/privateKey";
in
{
  config = lib.mkIf isRemoteClient {
    sops.secrets = {
      ${resticPasswordSecret} = { };
      ${resticSshKeySecret} = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };

    host.backups.jobs.${jobName} = {
      title = "Restic To ${jobTitle}";
      repository = {
        type = "sftp";
        path = client.repositoryPath;
        passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
        dependencyUnits = [ "sops-install-secrets.service" ];
        sftp = {
          host = backup.server.host;
          user = client.ingestUser;
          identityFile = config.sops.secrets.${resticSshKeySecret}.path;
        };
      };
    };
  };
}
