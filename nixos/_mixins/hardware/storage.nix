{ lib, ... }:
{
  options.host.hardware.storage = {
    mdraid = {
      enable = lib.mkEnableOption "Linux MD software RAID";

      recoverySpeedLimitMax = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Maximum MD background recovery speed in KiB/s.";
      };
    };

    smart = {
      enable = lib.mkEnableOption "SMART monitoring for local disks";

      devicePattern = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "^sd[a-z]+$";
        description = "Regular expression selecting devices for SMART metrics.";
      };
    };

    hba.enable = lib.mkEnableOption "StorCLI-managed host bus adapter";

    diskBays = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            rows = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Number of physical disk-bay rows.";
            };
            columns = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Number of physical disk-bay columns.";
            };
            mapping = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    bay = lib.mkOption {
                      type = lib.types.ints.positive;
                      description = "Chassis bay number.";
                    };
                    row = lib.mkOption {
                      type = lib.types.ints.positive;
                      description = "Physical row containing the bay.";
                    };
                    column = lib.mkOption {
                      type = lib.types.ints.positive;
                      description = "Physical column containing the bay.";
                    };
                    serial = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                      description = "Drive serial currently assigned to the bay.";
                    };
                    model = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                      description = "Drive model currently assigned to the bay.";
                    };
                  };
                }
              );
              default = [ ];
              description = "Static mapping from installed drives to physical bays.";
            };
            exporter.enable = lib.mkEnableOption "disk-bay mapping metrics export";
          };
        }
      );
      default = null;
      description = "Physical disk-bay layout exposed to fleet consumers.";
    };
  };
}
