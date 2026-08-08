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
    ./library-dirs.nix
    ./lolek.nix
    ./nginx.nix
    ./paperless-storage.nix
    ./pause.nix
    ./raid.nix
    ./sso.nix
  ];

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.blackbox.remote.enable = true;
  host.ups.scheduler.critical = true;
  # Exclude host-internal Podman bridge traffic from LAN/WAN accounting.
  host.observability.lanWan.interface = config.host.network.primaryInterface;

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
