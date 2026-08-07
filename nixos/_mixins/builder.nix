{
  config,
  hostInventory,
  lib,
  ...
}:
let
  upgradePolicy = hostInventory.autoUpgrade.builder;
in
{
  config = lib.mkIf config.host.isBuilder {
    system.autoUpgrade = {
      dates = lib.mkOverride 900 upgradePolicy.dates;
      rebootWindow = {
        lower = lib.mkOverride 900 upgradePolicy.rebootWindow.lower;
        upper = lib.mkOverride 900 upgradePolicy.rebootWindow.upper;
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
