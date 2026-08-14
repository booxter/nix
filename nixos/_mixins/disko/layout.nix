{
  device,
  rootPartition,
}:
{
  disko.devices.disk.main = {
    # When using disko-install, we will overwrite this value from the command line.
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        MBR = {
          type = "EF02"; # for GRUB MBR
          size = "1M";
          priority = 1; # Must be the first partition.
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
        ${rootPartition.name} = {
          size = "100%";
          inherit (rootPartition) content;
        };
      };
    };
  };

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
}
