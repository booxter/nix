{
  device ? "/dev/nvme0n1",
}:
let
  mountOptions = [
    "compress=zstd"
    "noatime"
  ];
in
import ./layout.nix {
  inherit device;
  rootPartition = {
    name = "luks";
    content = {
      type = "luks";
      name = "crypted";
      content = {
        type = "btrfs";
        extraArgs = [ "-f" ];
        subvolumes = {
          "/root" = {
            mountpoint = "/";
            inherit mountOptions;
          };
          "/home" = {
            mountpoint = "/home";
            inherit mountOptions;
          };
          "/nix" = {
            mountpoint = "/nix";
            inherit mountOptions;
          };
        };
      };
    };
  };
}
