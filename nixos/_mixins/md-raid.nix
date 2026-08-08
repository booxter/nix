{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.storage.mdRaid;
in
{
  options.host.storage.mdRaid = {
    enable = lib.mkEnableOption "Linux md software RAID";

    syncSpeedLimitKiBPerSecond = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20000;
      description = "Maximum background md synchronization speed in KiB per second.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot = {
      swraid = {
        enable = true;
        mdadmConf = "PROGRAM ${pkgs.util-linux}/bin/logger -t mdadm-monitor";
      };
      kernel.sysctl."dev.raid.speed_limit_max" = cfg.syncSpeedLimitKiBPerSecond;
    };

    environment.systemPackages = [ pkgs.mdadm ];
  };
}
