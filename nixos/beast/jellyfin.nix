{
  beastPkgs,
  config,
  hostInventory,
  utils,
  ...
}:
let
  dataMountPoint = config.host.storage.volumes.data.mounts.data.mountPoint;
  dataMountUnit = "${utils.escapeSystemdPath dataMountPoint}.mount";
  mediaExport = hostInventory.storage.nfs.exports.media;
in
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
  };

  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];

  systemd.services.jellyfin = {
    # If the data volume is slow during boot and /media mounts later, bring Jellyfin
    # back with the media bind mount instead of leaving nginx with a dead
    # upstream.
    wantedBy = [ "media.mount" ];
    unitConfig.RequiresMountsFor = "/media";
  };

  # Keep the existing /media path expected by Jellyfin/Jellarr.
  fileSystems."/media" = {
    device = mediaExport.path;
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=${dataMountPoint}"
      "x-systemd.wanted-by=${dataMountUnit}"
    ];
  };
}
