{ config, lib, ... }:
let
  volumes = config.host.storage.volumes;
  mountPoints = map (volume: volume.mountPoint) (builtins.attrValues volumes);
in
{
  assertions = [
    {
      assertion = builtins.length mountPoints == builtins.length (lib.unique mountPoints);
      message = "host.storage.volumes must use unique mount points";
    }
  ]
  ++ lib.mapAttrsToList (name: volume: {
    assertion = lib.hasPrefix "/" volume.mountPoint;
    message = "host.storage.volumes.${name}.mountPoint must be absolute";
  }) volumes
  ++ lib.mapAttrsToList (name: volume: {
    assertion = !volume.btrfs.snapshots.enable || volume.fileSystem.fsType == "btrfs";
    message = "host.storage.volumes.${name} must use Btrfs when snapshots are enabled";
  }) volumes;
}
