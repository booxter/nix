{
  hostInventory,
  pkgs,
  ...
}:
{
  imports = [
    (import ../disko { })
    ./backup-client.nix
    ./backup-server.nix
    ./jellyfin
    ./lolek.nix
  ];

  users.groups.media.gid = hostInventory.site.gids.media;

  host.storage.mdRaid.enable = true;
  host.ups.scheduler.critical = true;

  networking.resolvconf.enable = true;

  environment.systemPackages = with pkgs; [
    hdparm
    join-media-parts
    lm_sensors
    nvme-cli
  ];
}
