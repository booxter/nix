{
  config,
  hostInventory,
  lib,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  isOwner = paperlessService.owner == config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  dataDir = "/var/lib/paperless";
in
{
  config = lib.mkIf isOwner {
    host.backups.artifacts.postgresql.paperless = {
      job = backupJob;
      displayName = "Paperless";
      destinationDir = "/var/lib/paperless-backup/latest";
      requiresMountsFor = [ dataDir ];
    };

    host.backups.jobs.${backupJob}.paths = [
      dataDir
      config.host.nfs.mounts.paperless
    ];
  };
}
