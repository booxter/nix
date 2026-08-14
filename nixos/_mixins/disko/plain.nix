{
  device ? "/dev/nvme0n1",
}:
import ./layout.nix {
  inherit device;
  rootPartition = {
    name = "root";
    content = {
      type = "filesystem";
      format = "ext4";
      mountpoint = "/";
    };
  };
}
