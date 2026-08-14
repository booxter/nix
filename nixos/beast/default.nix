{ pkgs, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./jellarr
    ./jellyfin.nix
    ./storage.nix
  ];

  hardware.cpu.intel.updateMicrocode = true;

  host = {
    disko.layout = "plain";

    hardware.gpu = {
      vendors = [ "intel" ];
      render.device = "/dev/dri/renderD128";
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

    web.ingress = {
      enable = true;
      dynamicDns = {
        enable = true;
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
