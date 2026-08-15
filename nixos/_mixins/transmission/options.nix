{
  lib,
  pkgs,
  ...
}:
let
  dynamicIpUpdaterType = lib.types.submodule {
    options = {
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
  };
  trackerPolicyType = lib.types.submodule {
    options = {
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
  };
  torrentCleanerType = lib.types.submodule {
    options = {
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
  };
  uploadLimitType = lib.types.submodule {
    options.initialKBytesPerSecond = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Initial upload limit in kB/s before any runtime controller applies policy.";
    };
  };
in
{
  options.host.transmission = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
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
          dynamicIpUpdater = lib.mkOption {
            type = lib.types.nullOr dynamicIpUpdaterType;
            default = null;
          };
          vpn = {
            namespace = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "wg";
            };
            peerPort = lib.mkOption { type = lib.types.port; };
          };
          trackerPolicy = lib.mkOption {
            type = lib.types.nullOr trackerPolicyType;
            default = null;
          };
          torrentCleaner = lib.mkOption {
            type = lib.types.nullOr torrentCleanerType;
            default = null;
          };
          uploadLimit = lib.mkOption {
            type = lib.types.nullOr uploadLimitType;
            default = null;
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
    );
    default = null;
    description = "Transmission torrent downloader configuration.";
  };
}
