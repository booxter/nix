{
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
    ./jellarr.nix
    ./jellyfin.nix
    ./library-dirs.nix
    ./lolek.nix
    ./meilisearch.nix
    ./nginx.nix
    ./paperless-storage.nix
    ./pause.nix
    ./raid.nix
    ./sso.nix
    ./watchstate.nix
  ];

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.blackbox.remote.enable = true;
  host.ups.scheduler.critical = true;
  # Exclude host-internal Podman bridge traffic from LAN/WAN accounting.
  host.observability.lanWan.interface = "enp6s0";

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
