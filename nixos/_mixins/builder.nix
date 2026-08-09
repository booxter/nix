{ config, lib, ... }:
{
  config = lib.mkIf config.host.isBuilder {
    system.autoUpgrade = {
      dates = lib.mkOverride 900 "Mon 03:00";
      rebootWindow = {
        lower = lib.mkOverride 900 "02:59";
        upper = lib.mkOverride 900 "06:00";
      };
    };

    nix.settings = {
      auto-allocate-uids = true;
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
