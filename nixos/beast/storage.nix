{
  config,
  ...
}:
let
  dataVolume = config.host.storage.volumes.data;
  volume2 = dataVolume.mounts.data.mountPoint;
in
{
  # Keep the existing mount point for compatibility with storage consumers.
  fileSystems.${volume2} = {
    inherit (dataVolume) device fsType;
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=5min"
      "x-systemd.mount-timeout=15min"
    ];
  };
}
