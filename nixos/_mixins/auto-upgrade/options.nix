{ lib, ... }:
let
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
      availabilityGroup = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Group whose members must receive distinct maintenance slots.";
      };
      exclusions = lib.mkOption {
        type = lib.types.listOf exclusionType;
        default = [ ];
        description = "Cross-host maintenance exclusions requested by this role.";
      };
    };
  };
  holdType = lib.types.submodule {
    options = {
      startDate = lib.mkOption {
        type = lib.types.str;
        example = "2026-07-06";
        description = "Inclusive local start date for a NixOS auto-upgrade hold window in YYYY-MM-DD format.";
      };
      stopDate = lib.mkOption {
        type = lib.types.str;
        example = "2026-07-19";
        description = "Inclusive local stop date for a NixOS auto-upgrade hold window in YYYY-MM-DD format.";
      };
    };
  };
in
{
  options.host.autoUpgrade = {
    claims = lib.mkOption {
      type = lib.types.attrsOf claimType;
      default = { };
      description = "Role and relationship constraints used to plan unattended maintenance.";
    };

    holds = lib.mkOption {
      type = lib.types.listOf holdType;
      default = [ ];
      example = [
        {
          startDate = "2026-07-06";
          stopDate = "2026-07-19";
        }
      ];
      description = ''
        Inclusive local-date ranges during which unattended NixOS auto-upgrade
        maintenance should be skipped. Timers still fire on schedule, but the
        upgrade service and separately scheduled reboot service exit cleanly
        before they perform changes.
      '';
    };
  };
}
