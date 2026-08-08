{
  config,
  hostInventory,
  lib,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  isOwner = paperlessService.owner == config.networking.hostName;
  backupHost = hostInventory.realms.${config.host.realm}.services.backups.server.host;
  dataDir = "/var/lib/paperless";
in
{
  config = lib.mkIf isOwner {
    host.backups.artifacts.postgresql.paperless = {
      job = backupHost;
      displayName = "Paperless";
      destinationDir = "/var/lib/paperless-backup/latest";
      requiresMountsFor = [ dataDir ];
    };

    host.backups.jobs.${backupHost}.paths = [
      dataDir
      config.host.nfs.mounts.paperless
    ];
  };
}
