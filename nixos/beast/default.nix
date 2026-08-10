{
  inputs,
  pkgs,
  ...
}:
{
  system.stateVersion = "25.11";

  _module.args.beastPkgs = import ./pkgs { inherit inputs pkgs; };

  imports = [
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
  host.hardware.gpu = {
    vendors = [ "intel" ];
    renderDevice = "/dev/dri/renderD128";
  };
  host.network = {
    macAddress = "bc:fc:e7:3b:fe:da";
    primaryInterface = "enp6s0";
    reservation = {
      enable = true;
      address = "192.168.16.3";
    };
  };
  host.ups = {
    server = {
      description = "APC Back-UPS RS 1500MS2";
    };
    shutdown.critical = true;
  };

  networking.resolvconf.enable = true;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
