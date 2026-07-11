{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.fleetCacheWarmer;
  warmerPackage = pkgs.callPackage ../../pkgs/fleet-cache-warmer {
    name = cfg.serviceName;
    inherit (cfg) pushToAttic targetFilter;
  };
in
{
  options.host.fleetCacheWarmer = {
    enable = lib.mkEnableOption "scheduled fleet cache warming";

    targetFilter = lib.mkOption {
      type = lib.types.enum [
        "non-work"
        "work"
      ];
      default = "non-work";
      description = "Which CI inventory targets to warm, based on host isWork flags.";
    };

    pushToAttic = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to push successfully built outputs to Attic after warming.";
    };

    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = "github:booxter/nix";
      description = "Flake reference to warm.";
    };

    atticCache = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Attic cache name used when pushToAttic is enabled.";
    };

    serviceName = lib.mkOption {
      type = lib.types.str;
      default = "fleet-cache-warmer";
      description = "launchd service label and command name.";
    };

    startCalendarInterval = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.int);
      default = [
        {
          Hour = 8;
          Minute = 30;
        }
        {
          Hour = 20;
          Minute = 30;
        }
      ];
      description = "launchd calendar intervals for the scheduled warmups.";
    };

    rootDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/root";
      description = "Root home and working directory for the warmer daemon.";
    };

    logPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/fleet-cache-warmer.log";
      description = "Path for warmer stdout and stderr.";
    };
  };

  config = lib.mkIf cfg.enable {
    launchd.daemons.${cfg.serviceName} = {
      serviceConfig = {
        ProgramArguments = [
          (lib.getExe warmerPackage)
        ];
        StartCalendarInterval = cfg.startCalendarInterval;
        WorkingDirectory = cfg.rootDir;
        EnvironmentVariables = {
          HOME = cfg.rootDir;
          FLEET_CACHE_WARMER_FLAKE = cfg.flakeRef;
        }
        // lib.optionalAttrs cfg.pushToAttic {
          FLEET_CACHE_WARMER_ATTIC_CACHE = cfg.atticCache;
          NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        };
        ProcessType = "Background";
        StandardOutPath = cfg.logPath;
        StandardErrorPath = cfg.logPath;
      };
    };
  };
}
