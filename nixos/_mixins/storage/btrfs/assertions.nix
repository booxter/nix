{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.storage.btrfs;
  helpers = import ./lib.nix { inherit lib utils; };
  enabledSnapshots = lib.filterAttrs (_: snapshot: snapshot.enable) cfg.snapshots;
  snapshotNames = lib.mapAttrsToList (
    mountPoint: _: helpers.snapshotName mountPoint
  ) enabledSnapshots;
in
{
  config.assertions =
    lib.concatMap (
      mountPoint:
      let
        fileSystem = config.fileSystems.${mountPoint} or null;
      in
      [
        {
          assertion = fileSystem != null;
          message = "Btrfs snapshots require a filesystem mounted at '${mountPoint}'";
        }
        {
          assertion = fileSystem == null || fileSystem.fsType == "btrfs";
          message = "Btrfs snapshots require '${mountPoint}' to use fsType = \"btrfs\"";
        }
      ]
    ) (builtins.attrNames enabledSnapshots)
    ++ [
      {
        assertion = builtins.length snapshotNames == builtins.length (lib.unique snapshotNames);
        message = "Btrfs snapshot mount points must produce unique Snapper configuration names";
      }
    ];
}
