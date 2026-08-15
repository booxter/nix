{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  rootDir = "/root";
  atticConfigPath = "${rootDir}/.config/attic/config.toml";
  servers = config.host.attic.realmServers;
  watchStoreCommand =
    name: server:
    utils.escapeSystemdExecArgs [
      (lib.getExe pkgs.attic-client)
      "watch-store"
      "${name}:${server.cacheName}"
    ];
in
{
  config = lib.mkIf (servers != { }) {
    host.autoUpgrade.claims.attic-client.exclusions = map (server: {
      hosts = [ server.hostName ];
      minimumGapMinutes = 5;
    }) (builtins.attrValues servers);

    systemd.services = lib.mapAttrs' (
      name: server:
      lib.nameValuePair "attic-watch-store-${name}" {
        description = "Watch the Nix store and push new paths to Attic";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.HOME = rootDir;
        serviceConfig = {
          ExecStart = watchStoreCommand name server;
          Restart = "always";
          RestartSec = "15s";
          WorkingDirectory = rootDir;
        };
      }
    ) servers;

    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${atticConfigPath}")"
      ${pkgs.coreutils}/bin/ln -sf ${
        config.sops.templates."attic-client-config.toml".path
      } "${atticConfigPath}"
    '';
  };
}
