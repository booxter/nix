{
  host.storage.volumes.bulk = {
    # Keep /volume2 as the durable path published to existing NFS clients.
    mountPoint = "/volume2";
    fileSystem = {
      device = "/dev/disk/by-uuid/6c1ea7bf-4fd8-482a-aa6e-a35129c628e6";
      fsType = "btrfs";
      options = [
        "compress=zstd"
        "noatime"
      ];
    };
    activation.slow = true;
    requiredAtBoot = true;
    btrfs.snapshots.enable = true;
  };

  host.storage.resources = {
    media = {
      volume = "bulk";
      relativePath = "Media";
      sharedGroup = "media";
      directoryDefaults = {
        group = "media";
        mode = "2775";
        enforce = true;
      };
      identities.groups = [ "media" ];
      nfs = {
        enable = true;
        fsid = 10;
      };
    };
    nixCache = {
      volume = "bulk";
      relativePath = "nix-cache";
      nfs = {
        enable = true;
        fsid = 11;
      };
    };
    paperless = {
      volume = "bulk";
      relativePath = "paperless";
      directoryDefaults = {
        owner = "paperless";
        group = "paperless";
        mode = "0750";
      };
      identities = {
        groups = [ "paperless" ];
        users = [ "paperless" ];
      };
      nfs = {
        enable = true;
        fsid = 12;
        anonymousIdentity = "paperless";
      };
    };
  };

  host.hardware.storage = {
    mdraid = {
      enable = true;
      # Keep reshape and recovery I/O gentle enough for media serving.
      recoverySpeedLimitMax = 20000;
    };

    smart.enable = true;

    hba.backend = "storcli";

    diskBays = {
      rows = 5;
      columns = 3;
      mapping = [
        {
          bay = 1;
          row = 1;
          column = 1;
          serial = "ZYD01W48";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 3;
          row = 3;
          column = 1;
          serial = "ZYD0CASB";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 5;
          row = 5;
          column = 1;
          serial = "ZYD05Z4J";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 6;
          row = 1;
          column = 2;
          serial = "ZYD041CP";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 7;
          row = 2;
          column = 2;
          serial = "ZXA0RKFF";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 9;
          row = 4;
          column = 2;
          serial = "ZXA0B5K4";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 10;
          row = 5;
          column = 2;
          serial = "ZXA0FFNN";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 11;
          row = 1;
          column = 3;
          serial = "ZYD01W92";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 12;
          row = 2;
          column = 3;
          serial = "ZXA0GW38";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 13;
          row = 3;
          column = 3;
          serial = "ZYD02EQQ";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 15;
          row = 5;
          column = 3;
          serial = "ZXA0ENE4";
          model = "ST24000NM000C-3WD103";
        }
      ];
      exporter.enable = true;
    };
  };
}
