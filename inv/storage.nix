let
  beast = "beast";
  dataVolume = {
    device = "/dev/disk/by-uuid/6c1ea7bf-4fd8-482a-aa6e-a35129c628e6";
    fsType = "btrfs";
    mounts.data = {
      mountPoint = "/volume2";
      requiredForBoot = false;
    };
  };
  export = path: fsid: {
    server = beast;
    path = "${dataVolume.mounts.data.mountPoint}/${path}";
    inherit fsid;
  };
in
{
  hosts.${beast}.volumes.data = dataVolume;
  hosts.frame.volumes.system = {
    device = "/dev/mapper/crypted";
    fsType = "btrfs";
    mounts = {
      root.mountPoint = "/";
      home.mountPoint = "/home";
      nix = {
        mountPoint = "/nix";
        snapshots = false;
      };
    };
  };

  nfs.exports = {
    media = export "Media" 10;
    nixCache = export "nix-cache" 11;
    paperless = export "paperless" 12;
  };
}
