{
  lib,
  pkgs,
  ...
}:
{
  options.host.transmission = {
    enable = lib.mkEnableOption "Transmission torrent downloader";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.transmission_4;
    };

    stateDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/var/lib/transmission";
    };

    storage = {
      claim = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "media";
      };
      relativePath = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "torrents";
      };
    };

    dynamicIpUpdater = {
      enable = lib.mkEnableOption "MyAnonamouse dynamic seedbox IP updates";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./pkgs/dynamic-ip-updater {
          atomicFileWrites = pkgs.atomic-file-writes;
        };
        internal = true;
      };

      cookieJarFile = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        description = "Netscape cookie jar used to authenticate dynamic IP updates.";
      };
    };

    vpn = {
      namespace = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "wg";
      };
      peerPort = lib.mkOption {
        type = lib.types.port;
      };
    };

    trackerPolicy = {
      enable = lib.mkEnableOption "private-tracker prioritization";

      secret.key = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "transmission/private_tracker_hosts";
      };

      nonPreferred = {
        lowPriorityRatio = lib.mkOption {
          type = lib.types.number;
          default = 3.0;
        };
        pauseRatio = lib.mkOption {
          type = lib.types.number;
          default = 6.0;
        };
      };

      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
      };

      requestTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
      };
    };

    torrentCleaner = {
      enable = lib.mkEnableOption "periodic cleanup of old public torrents";

      minimumAgeDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
      };

      minimumRatio = lib.mkOption {
        type = with lib.types; nullOr number;
        default = null;
        description = "Minimum public torrent ratio, or null to use the tracker policy threshold.";
      };

      maximumAgeDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 365;
      };

      schedule = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "15m";
      };

      delete = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

    uploadLimit = {
      enable = lib.mkEnableOption "Transmission upload limiting";

      initialKBytesPerSecond = lib.mkOption {
        type = with lib.types; nullOr ints.positive;
        default = null;
        description = "Initial upload limit in kB/s before any runtime controller applies policy.";
      };
    };

    rpcUrl = lib.mkOption {
      type = lib.types.nonEmptyStr;
      readOnly = true;
      internal = true;
    };

    rpcPort = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      internal = true;
    };

    completeDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      readOnly = true;
      internal = true;
    };

    incompleteDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      readOnly = true;
      internal = true;
    };

    watchDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      readOnly = true;
      internal = true;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "transmission";
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
      internal = true;
    };
  };
}
