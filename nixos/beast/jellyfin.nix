{
  config,
  hostInventory,
  ...
}:
{
  services.jellyfin = {
    enable = true;
    builtInBackup = {
      enable = true;
      backupJob = "beast";
      group = "restic-cloud";
      stagingDir = "${config.host.storage.volumes.data.mounts.data.mountPoint}/backups/staging/jellyfin";
    };
    exporter.enable = true;
    logging.playbackDebug = true;
    maintenance = {
      enable = true;
      units = [
        "nixos-upgrade"
        "nixos-weekly-reboot-if-needed"
      ];
    };
    mediaMount = {
      enable = true;
      source = hostInventory.storage.nfs.exports.media.path;
      sourceMount = config.host.storage.volumes.data.mounts.data.mountPoint;
    };
    meilisearch.enable = true;
    supplementaryGroups = [
      "media"
      "render"
      "video"
    ];
  };
}
