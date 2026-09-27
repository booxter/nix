{ config, lib, ... }:
let
  GiB = 1024 * 1024 * 1024;
in
{
  config = lib.mkMerge [
    (lib.mkIf (config.host.nix.builder != null) {
      boot.kernel.sysctl."vm.swappiness" = lib.mkDefault 10;
      host.autoUpgrade.claims.builder = {
        switch.cadence = "weekly";
        reboot.cadence = "weekly";
        availabilityGroup = "builders:${config.host.realm}";
      };
      nix.settings = {
        auto-allocate-uids = true;
        use-cgroups = true;
        extra-experimental-features = [
          "auto-allocate-uids"
          "cgroups"
        ];
        extra-system-features = [
          "devnet"
          "uid-range"
        ];
        extra-sandbox-paths = [ "/dev/net" ];
      };
      swapDevices = [
        {
          device = "/var/lib/swapfile";
          size = 16 * 1024;
          randomEncryption.enable = true;
        }
      ];
    })
    (lib.mkIf (config.host.nix.builder != null && config.host.proxmox.guest != null) {
      boot.kernel.sysctl."vm.swappiness" = 100;
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryMax = 16 * GiB;
        priority = 100;
      };
    })
  ];
}
