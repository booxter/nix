{
  beastPkgs,
  config,
  hostInventory,
  ...
}:
{
  services.jellyfin = {
    enable = true;
    exporter.enable = true;
    logging.playbackDebug = true;
    maintenance = {
      enable = true;
      package = beastPkgs.jellyfin-tools;
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
  };

  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];

}
