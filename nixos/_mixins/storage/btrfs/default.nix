{ lib, ... }:
let
  retentionOption =
    description: default:
    lib.mkOption {
      type = lib.types.ints.unsigned;
      inherit default description;
    };
in
{
  imports = [
    ./assertions.nix
    ./config.nix
  ];

  options.host.storage.btrfs = {
    snapshots = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            retention = {
              hourly = retentionOption "Hourly snapshots to retain." 0;
              daily = retentionOption "Daily snapshots to retain." 7;
              weekly = retentionOption "Weekly snapshots to retain." 4;
              monthly = retentionOption "Monthly snapshots to retain." 6;
              yearly = retentionOption "Yearly snapshots to retain." 1;
            };
          };
        }
      );
      default = { };
      description = "Snapshot policy keyed by Btrfs mount point.";
    };
  };
}
