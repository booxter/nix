{
  config,
  hostInventory,
  ...
}:
let
  localRepoPasswordSecret = "backup/restic/beast/cloud/localPassword";
  localRepo = hostInventory.backups.clients.${config.networking.hostName}.repositoryPath;
in
{
  host.backups.jobs.beast = {
    title = "Beast Local Restic";
    user = "restic-cloud";
    repository = {
      type = "local";
      path = localRepo;
      passwordFile = config.sops.secrets.${localRepoPasswordSecret}.path;
      dependencyUnits = [ "sops-install-secrets.service" ];
    };
    timerConfig = {
      OnCalendar = "04:45";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
