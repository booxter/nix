{
  config,
  fleetInventory,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.cacheWarmer.fleet;
  stateDir = "/var/lib/fleet-cache-warmer";
  textfileDir = "${stateDir}/textfile";
  pushToAttic = config.host.attic.realmServers != { };
  fleetTargets = map (target: target.attr) (
    lib.filter (
      target: fleetInventory.hosts.${target.host}.realm == config.host.realm
    ) outputs.lib.ciTargets.buildTargets
  );
  checkTargets = lib.concatMap (
    system: map (name: "checks.${system}.${name}") (builtins.attrNames outputs.checks.${system})
  ) (builtins.attrNames outputs.checks);
  warmTargets = fleetTargets ++ checkTargets;
  atticCaches = lib.mapAttrsToList (
    name: server: "${name}:${server.cacheName}"
  ) config.host.attic.realmServers;
  package = pkgs.callPackage ./pkgs/fleet-cache-warmer {
    inherit pushToAttic warmTargets;
  };
in
{
  options.host.nix.cacheWarmer.fleet.enable = lib.mkEnableOption "scheduled fleet cache warming";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        launchd.daemons.fleet-cache-warmer = {
          command = lib.escapeShellArgs [ (lib.getExe package) ];
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
              NIX_CONFIG = "builders = ${config.host.nix.cacheWarmer.builders}";
            }
            // lib.optionalAttrs config.host.observability.enable {
              FLEET_CACHE_WARMER_STATE_FILE = "${stateDir}/status.json";
              FLEET_CACHE_WARMER_METRICS_FILE = "${textfileDir}/state.prom";
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
      }
      (lib.mkIf config.host.observability.enable {
        host.observability.nodeExporter.textfile.directories.fleetCacheWarmer = textfileDir;

        system.activationScripts.postActivation.text = lib.mkAfter ''
          install -d -m 0755 -o root -g wheel ${stateDir} ${textfileDir}
        '';
      })
    ]
  );
}
