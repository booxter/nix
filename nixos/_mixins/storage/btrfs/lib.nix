{
  lib,
  utils,
}:
{
  btrfsMounts =
    fileSystems:
    let
      mounts = lib.mapAttrsToList (mountPoint: fileSystem: {
        inherit mountPoint;
        inherit (fileSystem) device;
      }) (lib.filterAttrs (_: fileSystem: fileSystem.fsType == "btrfs") fileSystems);
    in
    lib.foldl' (
      result: mount:
      if lib.any (existing: existing.device == mount.device) result then result else result ++ [ mount ]
    ) [ ] mounts;

  mountUnit = mountPoint: "${utils.escapeSystemdPath mountPoint}.mount";

  scrubUnitSuffix = utils.escapeSystemdPath;

  snapshotsPath = mountPoint: if mountPoint == "/" then "/.snapshots" else "${mountPoint}/.snapshots";

  snapshotName =
    mountPoint:
    if mountPoint == "/" then
      "root"
    else
      lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" mountPoint);
}
