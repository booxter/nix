{ lib, ... }:
{
  options.hardware = {
    drmCard = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "DRM card that owns the configured displays.";
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
