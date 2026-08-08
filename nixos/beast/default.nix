{
  hostInventory,
  inputs,
  pkgs,
  ...
}:
{
  _module.args.beastPkgs = import ./pkgs { inherit inputs pkgs; };

  imports = [
    (import ../disko { })
    ./backup-server.nix
    ./jellarr.nix
    ./jellyfin-backup.nix
    ./jellyfin-exporter.nix
    ./jellyfin-maintenance.nix
    ./jellyfin.nix
    ./library-dirs.nix
    ./lolek.nix
    ./meilisearch.nix
    ./nfs.nix
    ./nginx.nix
    ./pause.nix
    ./raid.nix
    ./sso.nix
    ./ups.nix
    ./watchstate.nix
  ];

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.blackbox.remote.enable = true;
  # Exclude host-internal Podman bridge traffic from LAN/WAN accounting.
  host.observability.lanWan.interface = "enp6s0";

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
