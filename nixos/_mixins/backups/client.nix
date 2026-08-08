{
  config,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  cfg = config.host.backups.client;
  isRemoteClient = cfg.enable && !cfg.isLocal;
  jobName = config.host.backups.destinationJob;
  jobTitle = "${lib.toUpper (lib.substring 0 1 jobName)}${
    lib.substring 1 (builtins.stringLength jobName) jobName
  }";
  resticPasswordSecret = "backup/restic/local/password";
  resticSshKeySecret = "backup/restic/local/ssh/privateKey";
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
          path = cfg.repositoryPath;
          passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
          dependencyUnits = [ "sops-install-secrets.service" ];
          sftp = {
            host = jobName;
            user = "restic-${hostname}";
            identityFile = config.sops.secrets.${resticSshKeySecret}.path;
          };
        };
      };
    })
    (lib.mkIf cfg.isLocal {
      host.backups.jobs.${jobName} = {
        title = "${jobTitle} Local Restic";
        user = config.host.backups.server.cloud.group;
        repository = {
          type = "local";
          path = cfg.repositoryPath;
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
