{ config, lib, ... }:
let
  volumes = config.host.storage.volumes;
  slowActivationOptions = [
    "x-systemd.device-timeout=5min"
    "x-systemd.mount-timeout=15min"
  ];
in
{
  fileSystems = lib.mapAttrs' (
    _: volume:
    lib.nameValuePair volume.mountPoint {
      inherit (volume) device fsType;
      options = volume.mountOptions ++ lib.optionals volume.slowActivation slowActivationOptions;
    }
  ) volumes;

  host.storage.btrfs.snapshots = lib.mkMerge (
    lib.mapAttrsToList (
      _: volume:
      lib.optionalAttrs volume.snapshots {
        ${volume.mountPoint} = { };
      }
    ) volumes
  );
}
