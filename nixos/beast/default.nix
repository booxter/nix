{ pkgs, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./jellarr
    ./jellyfin.nix
    ./storage.nix
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
    render.device = "/dev/dri/renderD128";
  };
  host.lolek.enable = true;
  host.autoUpgrade.reboot = {
    mode = "scheduled";
    calendar = "Sat 04:00";
  };
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
  host.watchstate = {
    enable = true;
    backups.stagingDirectory = "/volume2/backups/staging/watchstate";
  };

  environment.systemPackages = [ pkgs.join-media-parts ];
}
