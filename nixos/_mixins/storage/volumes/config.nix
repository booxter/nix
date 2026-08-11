{ config, lib, ... }:
let
  volumes = config.host.storage.volumes;
  timeoutOptions =
    volume:
    let
      deviceTimeout =
        if volume.activation.deviceTimeout != null then
          volume.activation.deviceTimeout
        else if volume.activation.slow then
          "5min"
        else
          null;
      mountTimeout =
        if volume.activation.mountTimeout != null then
          volume.activation.mountTimeout
        else if volume.activation.slow then
          "15min"
        else
          null;
    in
    lib.optional (deviceTimeout != null) "x-systemd.device-timeout=${deviceTimeout}"
    ++ lib.optional (mountTimeout != null) "x-systemd.mount-timeout=${mountTimeout}";
in
{
  fileSystems = lib.mapAttrs' (
    _: volume:
    lib.nameValuePair volume.mountPoint {
      inherit (volume.fileSystem) device fsType;
      options =
        volume.fileSystem.options
        ++ lib.optional (!volume.requiredAtBoot) "nofail"
        ++ timeoutOptions volume;
    }
  ) volumes;

  host.storage.btrfs.snapshots = lib.mkMerge (
    lib.mapAttrsToList (
      _: volume:
      lib.optionalAttrs volume.btrfs.snapshots.enable {
        ${volume.mountPoint}.enable = true;
      }
    ) volumes
  );
}
