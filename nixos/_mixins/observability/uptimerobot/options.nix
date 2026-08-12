{
  lib,
  pkgs,
  ...
}:
{
  options.host.observability.uptimeRobot.controller = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this node authoritatively reconciles every monitor in the UptimeRobot account.";
    };

    capacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Maximum number of monitors available to the external-probe planner.";
    };

    planner = {
      spreadByOwner = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether services at the same importance should be spread across owner hosts.";
      };

      minimumImportance = lib.mkOption {
        type = lib.types.enum [
          "critical"
          "important"
          "normal"
          "best-effort"
        ];
        default = "best-effort";
        description = "Lowest service importance eligible for UptimeRobot selection.";
      };
    };

    monitorInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "UptimeRobot polling interval in seconds.";
    };

    apiUrl = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "https://api.uptimerobot.com/v3";
      description = "UptimeRobot API base URL.";
    };

    apiKeySecret = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "uptimerobot/api_key";
      description = "SOPS secret containing the UptimeRobot API key.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package { }";
      description = "UptimeRobot reconciliation package.";
    };

    schedule = {
      onBootSec = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "5m";
        description = "Delay before the first reconciliation after boot.";
      };
      onUnitActiveSec = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "1h";
        description = "Interval between reconciliations.";
      };
      randomizedDelaySec = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "10m";
        description = "Maximum randomized timer delay.";
      };
    };

    plan = {
      selectedServiceIds = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        readOnly = true;
        internal = true;
        description = "Service IDs selected by the external-probe planner.";
      };
      omittedServiceIds = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        readOnly = true;
        internal = true;
        description = "Eligible service IDs omitted because controller capacity was exhausted.";
      };
    };
  };
}
