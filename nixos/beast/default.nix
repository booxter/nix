{ pkgs, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./jellarr
    ./jellyfin.nix
    ./storage.nix
  ];

  hardware.cpu.intel.updateMicrocode = true;

  host.observability.blackbox.remote.enable = true;
  host.web.ingress = {
    enable = true;
    dynamicDns = {
      enable = true;
      hostname = "ihrachyshka-beast.freeddns.org";
      username = "ihrachyshka";
    };
  };
  host.backups = {
    destinations.primary.server = "beast";
    server = {
      enable = true;
      repositoryRoot = "/volume2/backups/restic-prod/hosts";
      offsite = {
        enable = true;
        backend = "s3";
        bucketName = "ihar-restic-prod";
        qos.enable = true;
        repositoryRoot = "s3:https://s3.us-east-005.backblazeb2.com/ihar-restic-prod/hosts";
        storageProvider = "b2";
      };
    };
  };
  host.hardware.gpu = {
    vendors = [ "intel" ];
    render.device = "/dev/dri/renderD128";
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
      enable = true;
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
