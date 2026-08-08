{
  config,
  hostInventory,
  ...
}:
{
  imports = [
    ./jellarr-libraries.nix
    ./jellarr-users.nix
    ./jellarr.nix
    ./watchstate.nix
  ];

  services.jellyfin = {
    enable = true;
    builtInBackup = {
      enable = true;
      backupJob = "beast";
      group = "restic-cloud";
      stagingDir = "${config.host.storage.volumes.data.mounts.data.mountPoint}/backups/staging/jellyfin";
    };
    downloadLimiter = {
      enable = true;
      publicHost = hostInventory.servicesById.jellyfin.publicHost;
      unlimitedNetworks = [
        "127.0.0.0/8"
        "::1"
        hostInventory.site.lan.cidr
        "fe80::/10"
        "fc00::/7"
      ];
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
    supplementaryGroups = [ "media" ];
    useHostVideoAcceleration = true;
  };

  host.publicIngress.exports.jellyfin = {
    inherit (hostInventory.servicesById.jellyfin) publicHost;
    backend = {
      type = "local-http";
      url = config.services.jellyfin.localUrl;
    };
  };
}
