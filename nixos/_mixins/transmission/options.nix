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
  capabilityType = lib.types.submodule { };
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
          trackerPolicy = lib.mkOption {
            type = lib.types.nullOr capabilityType;
            default = null;
          };
          torrentCleaner = lib.mkOption {
            type = lib.types.nullOr capabilityType;
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
