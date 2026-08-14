{ pkgs, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./jellyfin
    ./storage.nix
  ];

  hardware.cpu.intel.updateMicrocode = true;

  host = {
    disko.layout = "plain";

    hardware.gpu = {
      vendor = "intel";
      renderDevice = "/dev/dri/renderD128";
    };

    network = {
      interfaces = {
        enp6s0 = {
          kind = "ethernet";
          disablePauseFrames = true;
        };
        enp7s0 = {
          kind = "ethernet";
          disablePauseFrames = true;
        };
      };
      primaryInterface = "enp6s0";
    };

    ups = {
      server = {
        description = "APC Back-UPS RS 1500MS2";
        waitForLowBattery = true;
      };
    };

    backups = {
      destination.server = "beast";
      server = {
        repositoryRoot = "/volume2/backups/restic-prod/hosts";
        offsite = {
          backend = "s3";
          endpoint = "https://s3.us-east-005.backblazeb2.com";
          bucket = "ihar-restic-prod";
          prefix = "hosts";
          qos = true;
          storageProvider = "b2";
        };
      };
    };

    web.ingress = {
      dynamicDns = {
        hostname = "ihrachyshka-beast.freeddns.org";
        username = "ihrachyshka";
      };
    };
    observability.blackbox.remote.enable = true;

    lolek.enable = true;
    watchstate = {
      enable = true;
      backups.stagingDirectory = "/volume2/backups/staging/watchstate";
    };
  };

  environment.systemPackages = [ pkgs.join-media-parts ];
}
