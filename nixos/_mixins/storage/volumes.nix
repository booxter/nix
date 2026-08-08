{
  config,
  lib,
  pkgs,
  ...
}:
let
  systemDisk = config.host.storage.systemDisk;
  diskBays = config.host.storage.diskBays;
  localDisks =
    lib.optional (systemDisk != null) systemDisk ++ lib.optionals (diskBays != null) diskBays.disks;
  hasNvme = lib.any (disk: disk.transport == "nvme") localDisks;
  hasSataHdd = lib.any (disk: disk.transport == "sata" && disk.media == "hdd") localDisks;
  inventoryMounts = builtins.concatLists (
    map (
      volume:
      map (
        mount:
        mount
        // {
          inherit (volume) device fsType;
        }
      ) (builtins.attrValues volume.mounts)
    ) (builtins.attrValues config.host.storage.volumes)
  );
  mountOptions =
    mount:
    lib.optionals (mount.fsType == "btrfs") [
      "compress=zstd"
      "noatime"
    ]
    ++ lib.optionals (!mount.requiredForBoot) [
      "nofail"
      "x-systemd.device-timeout=5min"
      "x-systemd.mount-timeout=15min"
    ];
  fileSystem =
    mount:
    lib.nameValuePair mount.mountPoint {
      device = lib.mkDefault mount.device;
      fsType = lib.mkDefault mount.fsType;
      options = lib.mkDefault (mountOptions mount);
    };
in
{
  environment.systemPackages =
    lib.optional hasNvme pkgs.nvme-cli ++ lib.optional hasSataHdd pkgs.hdparm;

  fileSystems = builtins.listToAttrs (map fileSystem inventoryMounts);
}
