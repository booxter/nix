{
  config,
  lib,
  ...
}:
let
  systemDisk = config.host.storage.systemDisk;
  luks = systemDisk != null && systemDisk.layout == "luks-btrfs";
  rootContent =
    if luks then
      {
        type = "luks";
        name = "crypted";
        content = {
          type = "btrfs";
          extraArgs = [ "-f" ];
          subvolumes = {
            "/root" = {
              mountpoint = "/";
              mountOptions = [
                "compress=zstd"
                "noatime"
              ];
            };
            "/home" = {
              mountpoint = "/home";
              mountOptions = [
                "compress=zstd"
                "noatime"
              ];
            };
            "/nix" = {
              mountpoint = "/nix";
              mountOptions = [
                "compress=zstd"
                "noatime"
              ];
            };
          };
        };
      }
    else
      {
        type = "filesystem";
        format = "ext4";
        mountpoint = "/";
      };
in
{
  config = lib.mkIf (systemDisk != null) {
    disko.devices.disk.main = {
      inherit (systemDisk) device;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          MBR = {
            type = "EF02";
            size = "1M";
            priority = 1;
          };
          ESP = {
            type = "EF00";
            size = "1G";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          ${if luks then "luks" else "root"} = {
            size = "100%";
            content = rootContent;
          };
        };
      };
    };

    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };
}
