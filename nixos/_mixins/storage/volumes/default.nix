{ lib, ... }:
{
  imports = [
    ./assertions.nix
    ./config.nix
  ];

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

            fileSystem = {
              device = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Stable block-device path containing the ${name} filesystem.";
              };

              fsType = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Filesystem type used by the ${name} volume.";
              };

              options = lib.mkOption {
                type = with lib.types; listOf nonEmptyStr;
                default = [ ];
                description = "Filesystem-specific mount options for the ${name} volume.";
              };
            };

            requiredAtBoot = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether boot should fail when the ${name} volume cannot be mounted.";
            };

            activation = {
              slow = lib.mkEnableOption "extended activation time for the ${name} volume";

              deviceTimeout = lib.mkOption {
                type = with lib.types; nullOr nonEmptyStr;
                default = null;
                description = "Device discovery timeout, or null to derive it from the activation policy.";
              };

              mountTimeout = lib.mkOption {
                type = with lib.types; nullOr nonEmptyStr;
                default = null;
                description = "Filesystem mount timeout, or null to derive it from the activation policy.";
              };
            };

            btrfs.snapshots.enable = lib.mkEnableOption "Btrfs snapshots for the ${name} volume";
          };
        }
      )
    );
    default = { };
    description = "Named host-local storage volumes.";
  };
}
