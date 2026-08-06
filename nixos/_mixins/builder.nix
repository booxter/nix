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
  };
}
