{
  config,
  lib,
  pkgs,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
  imagePin = import ./image-pin.nix;
in
{
  options.host.romm = {
    enable = lib.mkEnableOption "RomM game library";

    container = import ../../_lib/oci-image-options.nix {
      inherit lib;
      pin = imagePin;
    };

    publicHostName = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Public hostname published for RomM.";
    };

    publicUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = if config.host.romm.enable then config.host.web.services.romm.public.url else null;
      readOnly = true;
      internal = true;
      description = "Resolved public RomM URL.";
    };

    stateDir = lib.mkOption {
      type = absolutePath;
      default = "/var/lib/romm";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5081;
      internal = true;
    };

    storage = {
      claim = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "media";
        description = "Storage claim containing the RomM library.";
      };
      relativePath = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "romm";
        description = "RomM data root below the selected storage claim.";
      };
    };

    database = {
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "romm";
        internal = true;
      };
      dataDir = lib.mkOption {
        type = absolutePath;
        default = "/var/lib/mysql";
        description = "MariaDB data directory used by the host-local RomM database.";
      };
    };

    cache.port = lib.mkOption {
      type = lib.types.port;
      default = 6380;
      internal = true;
    };

    backups = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      stagingDir = lib.mkOption {
        type = absolutePath;
        default = "/var/lib/romm-backup/latest";
      };
    };

    sso.application = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "romm";
      description = "Realm SSO application controlling RomM access tiers.";
    };

    toolsPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package { };
      internal = true;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "romm";
      internal = true;
    };
  };
}
