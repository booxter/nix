{
  config,
  hostInventory,
  pkgs,
  ...
}:
{
  _module.args.beastPkgs = import ./pkgs { inherit pkgs; };

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
  # Exclude host-internal Podman bridge traffic from LAN/WAN accounting.
  host.observability.lanWan.interface = config.host.network.primaryInterface;

  networking.resolvconf.enable = true;

  environment.systemPackages = with pkgs; [
    hdparm
    join-media-parts
    lm_sensors
    nvme-cli
  ];
}
