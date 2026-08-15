{
  lib,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
  imagePin = import ./image-pin.nix;
in
{
  options.host.romm = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          container = import ../../_lib/oci-image-options.nix {
            inherit lib;
            pin = imagePin;
          };

          publicHostName = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Public hostname published for RomM.";
          };

          stateDir = lib.mkOption {
            type = absolutePath;
            default = "/var/lib/romm";
          };

          database.dataDir = lib.mkOption {
            type = absolutePath;
            default = "/var/lib/mysql";
            description = "MariaDB data directory used by the host-local RomM database.";
          };

          backups.stagingDir = lib.mkOption {
            type = absolutePath;
            default = "/var/lib/romm-backup/latest";
          };
        };
      }
    );
    default = null;
    description = "RomM game library configuration.";
  };
}
