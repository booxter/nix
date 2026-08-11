{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  autoUpgradeTools = pkgs.callPackage ./pkgs/auto-upgrade-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  maintenanceLib = import ./lib.nix { inherit lib; };
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  clockType = lib.types.submodule {
    options = {
      hour = lib.mkOption {
        type = lib.types.ints.between 0 23;
      };
      minute = lib.mkOption {
        type = lib.types.ints.between 0 59;
      };
    };
  };
  cadenceType = lib.types.enum [
    "daily"
    "weekly"
    "never"
  ];
  weekdayType = lib.types.enum [
    "Mon"
    "Tue"
    "Wed"
    "Thu"
    "Fri"
    "Sat"
    "Sun"
  ];
  operationClaimType = lib.types.submodule {
    options = {
      cadence = lib.mkOption {
        type = with lib.types; nullOr cadenceType;
        default = null;
        description = "Maximum frequency allowed for this maintenance operation.";
      };
      weekday = lib.mkOption {
        type = with lib.types; nullOr weekdayType;
        default = null;
        description = "Required weekday when this operation has weekly cadence.";
      };
    };
  };
  exclusionType = lib.types.submodule {
    options = {
      hosts = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        description = "Hosts whose maintenance must not overlap this claim.";
      };
      operations = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "switch"
            "reboot"
          ]
        );
        default = [
          "switch"
          "reboot"
        ];
      };
      minimumGapMinutes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
      };
    };
  };
  claimType = lib.types.submodule {
    options = {
      switch = lib.mkOption {
        type = operationClaimType;
        default = { };
      };
      reboot = lib.mkOption {
        type = operationClaimType;
        default = { };
      };
      availabilityGroups = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [ ];
        description = "Groups whose members must receive distinct maintenance slots.";
      };
      exclusions = lib.mkOption {
        type = lib.types.attrsOf exclusionType;
        default = { };
        description = "Cross-host maintenance exclusions requested by this role.";
      };
    };
  };
  resolvedOperationType = lib.types.submodule {
    options = {
      cadence = lib.mkOption { type = cadenceType; };
      calendar = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
      };
      start = lib.mkOption {
        type = with lib.types; nullOr ints.unsigned;
      };
      weekday = lib.mkOption {
        type = with lib.types; nullOr weekdayType;
      };
    };
  };
  planType = lib.types.submodule {
    options = {
      switch = lib.mkOption { type = resolvedOperationType; };
      reboot = lib.mkOption {
        type = lib.types.submodule {
          options = {
            cadence = lib.mkOption { type = cadenceType; };
            calendar = lib.mkOption {
              type = with lib.types; nullOr nonEmptyStr;
            };
            start = lib.mkOption {
              type = with lib.types; nullOr ints.unsigned;
            };
            weekday = lib.mkOption {
              type = with lib.types; nullOr weekdayType;
            };
            mode = lib.mkOption {
              type = lib.types.enum [
                "with-upgrade"
                "scheduled"
                "never"
              ];
            };
            scheduledCalendar = lib.mkOption {
              type = with lib.types; nullOr nonEmptyStr;
            };
          };
        };
      };
    };
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

    policy = {
      allowedWindow = {
        start = lib.mkOption {
          type = clockType;
          default = {
            hour = 3;
            minute = 30;
          };
        };
        end = lib.mkOption {
          type = clockType;
          default = {
            hour = 6;
            minute = 30;
          };
        };
      };
      dailyAt = lib.mkOption {
        type = clockType;
        default = {
          hour = 5;
          minute = 15;
        };
      };
      deferredRebootAt = lib.mkOption {
        type = clockType;
        default = {
          hour = 4;
          minute = 0;
        };
      };
      weeklyDay = lib.mkOption {
        type = weekdayType;
        default = "Mon";
      };
      slotDurationMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
      };
      slotStepMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 40;
      };
      randomizedDelayMinutes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 5;
      };
    };

    claims = lib.mkOption {
      type = lib.types.attrsOf claimType;
      default = { };
      description = "Role and relationship constraints used to plan unattended maintenance.";
    };

    plan = lib.mkOption {
      type = planType;
      default = model.plan;
      readOnly = true;
      internal = true;
      description = "Resolved unattended maintenance plan for this host.";
    };

    schedule = {
      calendar = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = model.plan.switch.calendar;
        readOnly = true;
        internal = true;
        description = "Systemd calendar expression for unattended upgrades.";
      };

      randomizedDelay = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "${toString config.host.autoUpgrade.policy.randomizedDelayMinutes}min";
        readOnly = true;
        internal = true;
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
        default = model.plan.reboot.mode;
        readOnly = true;
        internal = true;
        description = "Whether unattended reboots happen with upgrades, on a separate schedule, or never.";
      };

      calendar = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = model.plan.reboot.scheduledCalendar;
        readOnly = true;
        internal = true;
        description = "Systemd calendar expression for separately scheduled required reboots.";
      };

      randomizedDelay = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "${toString config.host.autoUpgrade.policy.randomizedDelayMinutes}min";
        readOnly = true;
        internal = true;
        description = "Random delay applied to separately scheduled reboots.";
      };

      window = {
        lower = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = maintenanceLib.formatClock (
            maintenanceLib.clockMinutes config.host.autoUpgrade.policy.allowedWindow.start
          );
          readOnly = true;
          internal = true;
          description = "Start of the reboot window used by with-upgrade reboots.";
        };

        upper = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = maintenanceLib.formatClock (
            maintenanceLib.clockMinutes config.host.autoUpgrade.policy.allowedWindow.end
          );
          readOnly = true;
          internal = true;
          description = "End of the reboot window used by with-upgrade reboots.";
        };
      };
    };
  };

  config = {
    _module.args.autoUpgradeTools = autoUpgradeTools;

    host.autoUpgrade.claims.baseline = {
      switch.cadence = "daily";
      reboot.cadence = "daily";
    };

    host.autoUpgrade.holds = [
      {
        startDate = "2026-06-08";
        stopDate = "2026-06-28";
      }
    ];
  };
}
