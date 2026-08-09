{
  inputs,
  pkgs,
  ...
}:
{
  system.stateVersion = "25.11";

  _module.args.beastPkgs = import ./pkgs { inherit inputs pkgs; };

  imports = [
    ./sso.nix
    ./btrfs.nix
    ./igpu.nix
    ./jellyfin.nix
    ./jellyfin-maintenance.nix
    ./jellyfin-exporter.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
    ./meilisearch.nix
    ./lolek.nix
    ./nginx.nix
    ./pause.nix
    ./storage.nix
    ./watchstate.nix
  ];

  host.observability.blackbox.remote.enable = true;
  host.backups.server.enable = true;
  host.network = {
    primaryInterface = "enp6s0";
    reservation = {
      enable = true;
      address = "192.168.16.3";
      identifiers = [ "bc:fc:e7:3b:fe:da" ];
    };
  };
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
