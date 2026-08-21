{ lib, ... }:
{
  options.host.storage.volumes = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            mountPoint = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Absolute mount point for the ${name} volume.";
            };

            device = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Stable block-device path containing the ${name} filesystem.";
            };

            fsType = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Filesystem type used by the ${name} volume.";
            };

            mountOptions = lib.mkOption {
              type = with lib.types; listOf nonEmptyStr;
              default = [ ];
              description = "Filesystem-specific mount options for the ${name} volume.";
            };

            slowActivation = lib.mkEnableOption "extended activation time for the ${name} volume";

            snapshots = lib.mkEnableOption "Btrfs snapshots for the ${name} volume";
          };
        }
      )
    );
    default = { };
    description = "Named host-local storage volumes.";
  };
}
