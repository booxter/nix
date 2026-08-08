{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  backup = hostInventory.realms.${config.host.realm}.services.backups or null;
  isClient = backup != null && builtins.hasAttr hostname backup.clients;
  isLocalClient = isClient && hostname == backup.server.host;
  isRemoteClient = isClient && !isLocalClient;
  client = backup.clients.${hostname};
  jobName = backup.server.host;
  jobTitle = "${lib.toUpper (lib.substring 0 1 jobName)}${
    lib.substring 1 (builtins.stringLength jobName) jobName
  }";
  resticPasswordSecret = "backup/restic/local/password";
  resticSshKeySecret = "backup/restic/local/ssh/privateKey";
  storageName = client.storageName or hostname;
  serverStorage = hostInventory.storage.hosts.${backup.server.host};
  storage = backup.server.storage;
  repositoryRoot = "${
    serverStorage.volumes.${storage.volume}.mounts.${storage.mount}.mountPoint
  }/${storage.relativePath}";
  repositoryPath = "${repositoryRoot}/${storageName}";
  localRepoPasswordSecret = "backup/restic/${hostname}/cloud/localPassword";
in
{
  config = lib.mkMerge [
    (lib.mkIf isRemoteClient {
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
          path = repositoryPath;
          passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
          dependencyUnits = [ "sops-install-secrets.service" ];
          sftp = {
            host = backup.server.host;
            user = "restic-${hostname}";
            identityFile = config.sops.secrets.${resticSshKeySecret}.path;
          };
        };
      };
    })
    (lib.mkIf isLocalClient {
      host.backups.jobs.${jobName} = {
        title = "${jobTitle} Local Restic";
        user = config.host.backups.server.cloud.group;
        repository = {
          type = "local";
          path = repositoryPath;
          passwordFile = config.sops.secrets.${localRepoPasswordSecret}.path;
          dependencyUnits = [ "sops-install-secrets.service" ];
        };
        timerConfig = {
          OnCalendar = "04:45";
          RandomizedDelaySec = "5m";
          Persistent = true;
        };
      };
    })
  ];
}
