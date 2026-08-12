{
  config,
  facts,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.cacheWarmer;
  ci = import ../../../../ci { inherit facts lib; };
  warmTargets = map (target: target.attr) (
    lib.filter (
      target: facts.hosts.hostSpecsByName.${target.host}.realm == config.host.realm
    ) ci.buildTargets
  );
  atticCaches = lib.mapAttrsToList (
    name: server: "${name}:${server.cacheName}"
  ) config.host.attic.realmServers;
  warmerPackage = pkgs.callPackage ./pkgs/fleet-cache-warmer {
    inherit (cfg) pushToAttic;
    inherit warmTargets;
  };
in
{
  imports = [ ./assertions.nix ];

  options.host.nix.cacheWarmer = {
    enable = lib.mkEnableOption "scheduled fleet cache warming";

    pushToAttic = lib.mkOption {
      type = lib.types.bool;
      default = config.host.attic.realmServers != { };
      description = "Whether to push successfully built outputs to every Attic cache in this host's realm.";
    };

    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = "github:booxter/nix";
      description = "Flake reference to warm.";
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
    launchd.daemons.fleet-cache-warmer = {
      command = lib.escapeShellArgs [ (lib.getExe warmerPackage) ];
      serviceConfig = {
        StartCalendarInterval = cfg.startCalendarInterval;
        WorkingDirectory = cfg.rootDir;
        EnvironmentVariables = {
          HOME = cfg.rootDir;
          FLEET_CACHE_WARMER_FLAKE = cfg.flakeRef;
        }
        // lib.optionalAttrs cfg.pushToAttic {
          FLEET_CACHE_WARMER_ATTIC_CACHES = builtins.toJSON atticCaches;
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
