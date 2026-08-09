{ lib, ... }:
{
  options.hardware = {
    drmCard = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "DRM card that owns the configured displays.";
    };

    displayMode = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            width = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Display mode width in pixels.";
            };

            height = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Display mode height in pixels.";
            };

            refreshRate = lib.mkOption {
              type = lib.types.numbers.positive;
              description = "Display mode refresh rate in hertz.";
            };
          };
        }
      );
      default = null;
      description = "Display mode shared by the configured displays.";
    };

    scale = lib.mkOption {
      type = lib.types.nullOr lib.types.numbers.positive;
      default = null;
      description = "Scale shared by the configured displays.";
    };

    displays = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            position = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Stable position name for the display.";
            };

            connector = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "DRM connector used by the display.";
            };

            x = lib.mkOption {
              type = lib.types.int;
              description = "Horizontal display position.";
            };

            primary = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this is the primary display.";
            };
          };
        }
      );
      default = [ ];
      description = "Physical displays attached to the host.";
    };
  };
}
