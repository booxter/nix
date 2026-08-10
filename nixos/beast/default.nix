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
    ./storage.nix
    ./watchstate.nix
  ];

  host.observability.blackbox.remote.enable = true;
  host.web.ingress = {
    enable = true;
    dynamicDns = {
      enable = true;
      hostname = "ihrachyshka-beast.freeddns.org";
      username = "ihrachyshka";
    };
  };
  host.backups.server.enable = true;
  host.hardware.gpu = {
    vendors = [ "intel" ];
    renderDevice = "/dev/dri/renderD128";
  };
  host.lolek.enable = true;
  host.network = {
    ethernet.disablePauseFrames.enable = true;
    interfaces = {
      enp6s0.kind = "ethernet";
      enp7s0.kind = "ethernet";
    };
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
    shutdown.waitForLowBattery = true;
  };

  environment.systemPackages = [ pkgs.join-media-parts ];
}
