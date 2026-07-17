{
  hostInventory,
  inputs,
  pkgs,
  username,
  ...
}:
{
  _module.args.beastPkgs = import ./pkgs { inherit inputs pkgs; };

  imports = [
    (import ../disko { })
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
    ./jellystat.nix
    ./library-dirs.nix
    ./lolek.nix
    ./nfs.nix
    ./nginx.nix
    ./pause.nix
    ./raid.nix
    ./ups.nix
    ./watchstate.nix
  ];

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.client.blackbox.enable = true;
  host.observability.client.blackbox.mtls.enable = true;

  sops = {
    defaultSopsFile = ../../secrets/main/beast.yaml;
  };

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
