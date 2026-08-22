{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.cacheWarmer;
  nixpkgsStateDir = "/var/lib/nixpkgs-cache-warmer";
  nixpkgsTextfileDir = "${nixpkgsStateDir}/textfile";
  nixpkgsMetricsFile = "${nixpkgsTextfileDir}/state.prom";
  pushToAttic = config.host.attic.realmServers != { };
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  warmTargets = map (target: target.attr) (
    lib.filter (
      target: configurations.${target.host}.config.host.realm == config.host.realm
    ) outputs.lib.ciTargets.buildTargets
  );
  atticCaches = lib.mapAttrsToList (
    name: server: "${name}:${server.cacheName}"
  ) config.host.attic.realmServers;
  fleetWarmerPackage = pkgs.callPackage ./pkgs/fleet-cache-warmer {
    inherit pushToAttic warmTargets;
  };
  nixpkgsWarmerPackage = pkgs.callPackage ../../../../apps/nixpkgs-cache-warmer {
    runnerHost = if cfg.nixpkgs.runner == null then "" else cfg.nixpkgs.runner;
  };
  nixpkgsArguments = [
    (lib.getExe nixpkgsWarmerPackage)
    "run"
    "--maintainer"
    cfg.nixpkgs.maintainer
  ]
  ++ lib.concatMap (reference: [
    "--reference"
    reference
  ]) cfg.nixpkgs.references
  ++ lib.concatMap (system: [
    "--system"
    system
  ]) cfg.nixpkgs.systems
  ++ lib.concatMap (pattern: [
    "--exclude-pname-pattern"
    pattern
  ]) cfg.nixpkgs.excludePnamePatterns
  ++ lib.concatMap (cache: [
    "--cache"
    cache
  ]) atticCaches;
  escapeMetricLabel = value: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] value;
  configuredTargets = lib.concatMap (
    reference:
    map (system: {
      branch = lib.last (lib.splitString "/" reference);
      inherit system;
    }) cfg.nixpkgs.systems
  ) cfg.nixpkgs.references;
  nixpkgsExpectationsFile = pkgs.writeText "nixpkgs-cache-warmer-expectations.prom" (
    ''
      # HELP host_observability_nixpkgs_cache_warmer_target_configured Whether a branch and system target is configured for warming.
      # TYPE host_observability_nixpkgs_cache_warmer_target_configured gauge
    ''
    + lib.concatMapStrings (target: ''
      host_observability_nixpkgs_cache_warmer_target_configured{branch="${escapeMetricLabel target.branch}",system="${escapeMetricLabel target.system}"} 1
    '') configuredTargets
  );
in
{
  options.host.nix.cacheWarmer = {
    fleet.enable = lib.mkEnableOption "scheduled fleet cache warming";

    nixpkgs = {
      runner = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Authoritative host for nixpkgs cache-warmer status.";
      };

      enable = lib.mkEnableOption "nightly nixpkgs cache warming";

      references = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        description = "Nixpkgs flake references to warm.";
      };

      systems = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        description = "Nix systems to warm for every reference.";
      };

      maintainer = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "booxter";
        description = "Nixpkgs maintainer handle whose packages are selected.";
      };

      excludePnamePatterns = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        description = "Full-match regular expressions for package names to exclude.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.fleet.enable {
      launchd.daemons.fleet-cache-warmer = {
        command = lib.escapeShellArgs [ (lib.getExe fleetWarmerPackage) ];
        serviceConfig = {
          StartCalendarInterval = [
            {
              Hour = 8;
              Minute = 30;
            }
            {
              Hour = 20;
              Minute = 30;
            }
          ];
          WorkingDirectory = "/var/root";
          EnvironmentVariables = {
            HOME = "/var/root";
            FLEET_CACHE_WARMER_FLAKE = "github:booxter/nix";
          }
          // lib.optionalAttrs pushToAttic {
            FLEET_CACHE_WARMER_ATTIC_CACHES = builtins.toJSON atticCaches;
            NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
            SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          };
          ProcessType = "Background";
          StandardOutPath = "/var/log/nix-darwin/fleet-cache-warmer.log";
          StandardErrorPath = "/var/log/nix-darwin/fleet-cache-warmer.log";
        };
      };
    })

    (lib.mkIf (cfg.nixpkgs.runner != null) {
      environment.systemPackages = [ nixpkgsWarmerPackage ];
    })

    (lib.mkIf cfg.nixpkgs.enable {
      assertions = [
        {
          assertion = cfg.nixpkgs.runner != null;
          message = "host.nix.cacheWarmer.nixpkgs.runner must be set when warming is enabled";
        }
        {
          assertion = cfg.nixpkgs.references != [ ];
          message = "host.nix.cacheWarmer.nixpkgs.references must not be empty";
        }
        {
          assertion = cfg.nixpkgs.systems != [ ];
          message = "host.nix.cacheWarmer.nixpkgs.systems must not be empty";
        }
        {
          assertion = atticCaches != [ ];
          message = "nixpkgs cache warming requires at least one Attic cache";
        }
      ];

      system.activationScripts.postActivation.text = lib.mkAfter ''
        mkdir -p ${nixpkgsStateDir}
        chmod 0755 ${nixpkgsStateDir}
      '';

      launchd.daemons.nixpkgs-cache-warmer = {
        command = lib.escapeShellArgs nixpkgsArguments;
        serviceConfig = {
          StartCalendarInterval = [
            {
              Hour = 1;
              Minute = 0;
            }
          ];
          WorkingDirectory = "/var/root";
          EnvironmentVariables = {
            HOME = "/var/root";
            NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
            SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          }
          // lib.optionalAttrs config.host.observability.enable {
            NIXPKGS_CACHE_WARMER_METRICS_FILE = nixpkgsMetricsFile;
          };
          ProcessType = "Background";
          StandardOutPath = "/var/log/nix-darwin/nixpkgs-cache-warmer.log";
          StandardErrorPath = "/var/log/nix-darwin/nixpkgs-cache-warmer.log";
        };
      };
    })

    (lib.mkIf (cfg.nixpkgs.enable && config.host.observability.enable) {
      host.observability.nodeExporter.textfile.directories.nixpkgsCacheWarmer = nixpkgsTextfileDir;

      system.activationScripts.launchd.text = lib.mkAfter ''
        install -d -m 0755 -o root -g wheel ${nixpkgsTextfileDir}
        ln -sfn ${nixpkgsExpectationsFile} ${nixpkgsTextfileDir}/expectations.prom
      '';
    })
  ];
}
