{
  lib,
  pkgs,
  ...
}:
let
  autoUpgradeTools = pkgs.callPackage ./pkgs/auto-upgrade-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
in
{
  imports = [
    ./assertions.nix
    ./config.nix
    ./holds.nix
    ./metrics.nix
  ];

  options.host.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to upgrade this host automatically.";
    };

    schedule = {
      calendar = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "05:15";
        description = "Systemd calendar expression for unattended upgrades.";
      };

      randomizedDelay = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "5min";
        description = "Random delay applied to the unattended upgrade schedule.";
      };
    };

    reboot = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "with-upgrade"
          "scheduled"
          "never"
        ];
        default = "with-upgrade";
        description = "Whether unattended reboots happen with upgrades, on a separate schedule, or never.";
      };

      calendar = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Systemd calendar expression for separately scheduled required reboots.";
      };

      randomizedDelay = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "5min";
        description = "Random delay applied to separately scheduled reboots.";
      };

      window = {
        lower = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "04:00";
          description = "Start of the reboot window used by with-upgrade reboots.";
        };

        upper = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "06:00";
          description = "End of the reboot window used by with-upgrade reboots.";
        };
      };
    };
  };

  config = {
    _module.args.autoUpgradeTools = autoUpgradeTools;

    host.autoUpgrade.holds = [
      {
        startDate = "2026-06-08";
        stopDate = "2026-06-28";
      }
    ];
  };
}
