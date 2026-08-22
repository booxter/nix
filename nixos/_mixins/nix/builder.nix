{ config, lib, ... }:
{
  config = lib.mkIf (config.host.nix.builder != null) {
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
  };
}
