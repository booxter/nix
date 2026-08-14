{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.cacheWarmer;
  pushToAttic = config.host.attic.realmServers != { };
  warmTargets = map (target: target.attr) (
    lib.filter (
      target:
      let
        configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
      in
      configurations.${target.host}.config.host.realm == config.host.realm
    ) outputs.lib.ciTargets.buildTargets
  );
  atticCaches = lib.mapAttrsToList (
    name: server: "${name}:${server.cacheName}"
  ) config.host.attic.realmServers;
  warmerPackage = pkgs.callPackage ./pkgs/fleet-cache-warmer {
    inherit pushToAttic warmTargets;
  };
in
{
  options.host.nix.cacheWarmer.enable = lib.mkEnableOption "scheduled fleet cache warming";

  config = lib.mkIf cfg.enable {
    launchd.daemons.fleet-cache-warmer = {
      command = lib.escapeShellArgs [ (lib.getExe warmerPackage) ];
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
        StandardOutPath = "/var/log/fleet-cache-warmer.log";
        StandardErrorPath = "/var/log/fleet-cache-warmer.log";
      };
    };
  };
}
