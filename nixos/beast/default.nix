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
    ./backup-server.nix
    ./btrfs.nix
    ./disk-bays.nix
    ./igpu.nix
    ./jellyfin.nix
    ./jellyfin-exporter.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
    ./library-dirs.nix
    ./lolek.nix
    ./nfs.nix
    ./nginx.nix
    ./pause.nix
    ./raid.nix
    ./ups.nix
  ];

  # Pin the host to the current stable branch's 7.0 kernel line instead of
  # tracking the moving `linuxPackages_latest` alias.
  # TODO: switch to a versioned LTS kernel package once the stable branch
  # carries an LTS kernel in the 7.x series.
  boot.kernelPackages = pkgs.linuxPackages_7_0;

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.client.blackbox.enable = true;
  host.observability.client.blackbox.mtls.enable = true;

  sops = {
    defaultSopsFile = ../../secrets/beast.yaml;
  };

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
