{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.storage.mdRaid;
  diskBays = config.host.storage.diskBays;
  raidSets = if diskBays == null then { } else diskBays.raidSets;
  mdRaidSets = lib.filterAttrs (_: raidSet: raidSet.implementation == "md") raidSets;
  mdEnabled = mdRaidSets != { };
  bayNames = map (disk: disk.bay) diskBays.disks;
  raidSetAssertions = lib.concatLists (
    lib.mapAttrsToList (name: raidSet: [
      {
        assertion = raidSet.memberBays != [ ];
        message = "md RAID set ${name} must contain at least one disk bay";
      }
      {
        assertion = lib.length raidSet.memberBays == lib.length (lib.unique raidSet.memberBays);
        message = "md RAID set ${name} contains duplicate disk bays";
      }
      {
        assertion = lib.all (bay: builtins.elem bay bayNames) raidSet.memberBays;
        message = "md RAID set ${name} refers to an unknown disk bay";
      }
      {
        assertion = builtins.hasAttr raidSet.volume config.host.storage.volumes;
        message = "md RAID set ${name} refers to unknown volume ${raidSet.volume}";
      }
    ]) mdRaidSets
  );
in
{
  options.host.storage.mdRaid = {
    syncSpeedLimitKiBPerSecond = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20000;
      description = "Maximum background md synchronization speed in KiB per second.";
    };
  };

  config = lib.mkIf mdEnabled {
    assertions = raidSetAssertions;

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
