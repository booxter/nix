{
  config,
  hostInventory,
  inputs,
  pkgs,
  ...
}:
{
  system.stateVersion = "25.11";
  home-manager.users.${config.host.username}.home.stateVersion = "25.11";

  _module.args.beastPkgs = import ./pkgs { inherit inputs pkgs; };

  imports = [
    ./sso.nix
    ./backup-server.nix
    ./btrfs.nix
    ./disk-bays.nix
    ./igpu.nix
    ./jellyfin.nix
    ./jellyfin-maintenance.nix
    ./jellyfin-exporter.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
    ./meilisearch.nix
    ./library-dirs.nix
    ./lolek.nix
    ./nfs.nix
    ./nginx.nix
    ./pause.nix
    ./raid.nix
    ./watchstate.nix
  ];

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.blackbox.remote.enable = true;
  # Exclude host-internal Podman bridge traffic from LAN/WAN accounting.
  host.observability.lanWan.interface = "enp6s0";
  host.ups = {
    server = {
      description = "APC Back-UPS RS 1500MS2";
    };
    shutdown.critical = true;
  };

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
