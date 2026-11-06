{
  lib,
  ...
}:
let
  dynamicIpUpdaterType = lib.types.submodule {
    options.cookieJarFile = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      description = "Netscape cookie jar used to authenticate dynamic IP updates.";
    };
  };
  trackerRetentionType = lib.types.submodule {
    options = {
      minimumRetained = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 100;
        description = "Minimum completed torrents to retain for this tracker alias.";
      };
      minimumSeedDays = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
        description = "Minimum actual seeding days before cleanup.";
      };
      minimumAgeDays = lib.mkOption {
        type = lib.types.addCheck lib.types.ints.unsigned (days: days >= 30);
        default = 30;
        description = "Minimum days since completion before cleanup.";
      };
    };
  };
  torrentPolicyType = lib.types.submodule {
    options = {
      trackers = lib.mkOption {
        type = lib.types.attrsOf trackerRetentionType;
        default = { };
        description = "Special tracker policies keyed by aliases from the encrypted hostname mapping.";
      };
      activityWindowDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 14;
      };
      minimumUploadKiBPerSecond = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Average upload rate that protects a special tracker torrent from cleanup.";
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
            peerPort = lib.mkOption { type = lib.types.port; };
          };
          torrentPolicy = lib.mkOption {
            type = lib.types.nullOr torrentPolicyType;
            default = null;
          };
          uploadLimit = lib.mkOption {
            type = lib.types.nullOr uploadLimitType;
            default = null;
          };
        };
      }
    );
    default = null;
    description = "Transmission torrent downloader configuration.";
  };
}
