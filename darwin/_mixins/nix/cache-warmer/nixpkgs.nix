{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.cacheWarmer.nixpkgs;
  stateDir = "/var/lib/nixpkgs-cache-warmer";
  inventoryCacheFile = "${stateDir}/inventory.json";
  textfileDir = "${stateDir}/textfile";
  metricsFile = "${textfileDir}/state.prom";
  atticCaches = lib.mapAttrsToList (
    name: server: "${name}:${server.cacheName}"
  ) config.host.attic.realmServers;
  package = pkgs.callPackage ../../../../apps/nixpkgs-cache-warmer {
    runnerHost = if cfg.runner == null then "" else cfg.runner;
  };
  arguments = [
    (lib.getExe package)
    "run"
    "--maintainer"
    cfg.maintainer
    "--inventory-cache-file"
    inventoryCacheFile
    "--inventory-cache-max-age-days"
    "7"
  ]
  ++ lib.concatMap (reference: [
    "--reference"
    reference
  ]) cfg.references
  ++ lib.concatMap (system: [
    "--system"
    system
  ]) cfg.systems
  ++ lib.concatMap (pattern: [
    "--exclude-pname-pattern"
    pattern
  ]) cfg.excludePnamePatterns;
  escapeMetricLabel = value: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] value;
  configuredTargets = lib.concatMap (
    reference:
    map (system: {
      branch = lib.last (lib.splitString "/" reference);
      inherit system;
    }) cfg.systems
  ) cfg.references;
  expectationsFile = pkgs.writeText "nixpkgs-cache-warmer-expectations.prom" (
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
  options.host.nix.cacheWarmer.nixpkgs = {
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

  config = lib.mkMerge [
    (lib.mkIf (cfg.runner != null) {
      environment.systemPackages = [ package ];
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.runner != null;
          message = "host.nix.cacheWarmer.nixpkgs.runner must be set when warming is enabled";
        }
        {
          assertion = cfg.references != [ ];
          message = "host.nix.cacheWarmer.nixpkgs.references must not be empty";
        }
        {
          assertion = cfg.systems != [ ];
          message = "host.nix.cacheWarmer.nixpkgs.systems must not be empty";
        }
        {
          assertion = atticCaches != [ ];
          message = "nixpkgs cache warming requires at least one Attic cache";
        }
      ];

      system.activationScripts.postActivation.text = lib.mkAfter ''
        mkdir -p ${stateDir}
        chmod 0755 ${stateDir}
      '';

      launchd.daemons.nixpkgs-cache-warmer = {
        command = lib.escapeShellArgs arguments;
        serviceConfig = {
          StartCalendarInterval = lib.genList (index: {
            Hour = index * 4;
            Minute = 0;
          }) 6;
          WorkingDirectory = "/var/root";
          EnvironmentVariables = {
            HOME = "/var/root";
            NIX_CONFIG = "builders = ${config.host.nix.cacheWarmer.builders}";
            NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
            SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          }
          // lib.optionalAttrs config.host.observability.enable {
            NIXPKGS_CACHE_WARMER_METRICS_FILE = metricsFile;
          };
          ProcessType = "Background";
          StandardOutPath = "/var/log/nix-darwin/nixpkgs-cache-warmer.log";
          StandardErrorPath = "/var/log/nix-darwin/nixpkgs-cache-warmer.log";
        };
      };
    })

    (lib.mkIf (cfg.enable && config.host.observability.enable) {
      host.observability.nodeExporter.textfile.directories.nixpkgsCacheWarmer = textfileDir;

      system.activationScripts.launchd.text = lib.mkAfter ''
        install -d -m 0755 -o root -g wheel ${textfileDir}
        ln -sfn ${expectationsFile} ${textfileDir}/expectations.prom
      '';
    })
  ];
}
