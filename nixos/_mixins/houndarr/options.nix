{
  config,
  lib,
  pkgs,
  ...
}:
let
  optional = type: lib.types.nullOr type;
  optionalBool = optional lib.types.bool;
  optionalUnsigned = optional lib.types.ints.unsigned;
  optionalPositive = optional lib.types.ints.positive;
  passPolicyType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = optionalBool;
        default = null;
      };
      batchSize = lib.mkOption {
        type = optionalPositive;
        default = null;
      };
      cooldownDays = lib.mkOption {
        type = optionalUnsigned;
        default = null;
      };
      hourlyCap = lib.mkOption {
        type = optionalUnsigned;
        default = null;
      };
    };
  };
  policyType = lib.types.submodule {
    options = {
      missing = {
        enable = lib.mkOption {
          type = optionalBool;
          default = null;
        };
        batchSize = lib.mkOption {
          type = optionalPositive;
          default = null;
        };
        intervalMinutes = lib.mkOption {
          type = optionalPositive;
          default = null;
        };
        hourlyCap = lib.mkOption {
          type = optionalUnsigned;
          default = null;
        };
        cooldownDays = lib.mkOption {
          type = optionalUnsigned;
          default = null;
        };
        postReleaseGraceHours = lib.mkOption {
          type = optionalUnsigned;
          default = null;
        };
        hotRetryWindowHours = lib.mkOption {
          type = optionalUnsigned;
          default = null;
        };
        hotRetryIntervalHours = lib.mkOption {
          type = optionalPositive;
          default = null;
        };
        queueLimit = lib.mkOption {
          type = optionalUnsigned;
          default = null;
        };
        searchMode = lib.mkOption {
          type = optional (
            lib.types.enum [
              "item"
              "context"
            ]
          );
          default = null;
        };
      };

      cutoff = lib.mkOption {
        type = passPolicyType;
        default = { };
      };

      upgrades = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = optionalBool;
              default = null;
            };
            batchSize = lib.mkOption {
              type = optionalPositive;
              default = null;
            };
            cooldownDays = lib.mkOption {
              type = optional (lib.types.ints.between 7 lib.types.ints.maxValue);
              default = null;
            };
            hourlyCap = lib.mkOption {
              type = optionalUnsigned;
              default = null;
            };
            searchMode = lib.mkOption {
              type = optional (
                lib.types.enum [
                  "item"
                  "context"
                ]
              );
              default = null;
            };
            contextWindowSize = lib.mkOption {
              type = optionalPositive;
              default = null;
            };
          };
        };
        default = { };
      };

      schedule = {
        allowedTimeWindow = lib.mkOption {
          type = optional lib.types.str;
          default = null;
          description = "Houndarr time-window expression, or an empty string for all day.";
        };
        order = lib.mkOption {
          type = optional (
            lib.types.enum [
              "chronological"
              "random"
            ]
          );
          default = null;
        };
      };

      tags = {
        include = lib.mkOption {
          type = optional (lib.types.listOf lib.types.nonEmptyStr);
          default = null;
        };
        exclude = lib.mkOption {
          type = optional (lib.types.listOf lib.types.nonEmptyStr);
          default = null;
        };
      };
    };
  };
  instanceType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        api = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
          description = "Registered host.web.api consumed by this Houndarr instance.";
        };
        displayName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = lib.strings.toSentenceCase name;
        };
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        policy = lib.mkOption {
          type = optional policyType;
          default = null;
          description = "Selectively managed search policy, or null to preserve mutable policy.";
        };
      };
    }
  );
in
{
  options.host.houndarr = {
    enable = lib.mkEnableOption "Houndarr polite search scheduler";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package {
        aiosqlitepool = pkgs.callPackage ../../../pkgs/aiosqlitepool { };
      };
    };

    toolsPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./tools {
        houndarr = config.host.houndarr.package;
      };
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8877;
    };

    stateDir = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      default = "/var/lib/houndarr";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceType;
      default = { };
    };

    authProxy = {
      gate = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Existing oauth2-proxy gate protecting Houndarr.";
      };
      userHeader = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "X-User";
      };
    };

    backups.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    observability = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "2m";
      };
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "houndarr";
      internal = true;
    };
    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "houndarr";
      internal = true;
    };
  };
}
