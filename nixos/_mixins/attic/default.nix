{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  rootDir = "/root";
  watchStoreCommand = utils.escapeSystemdExecArgs [
    (lib.getExe pkgs.attic-client)
    "watch-store"
    "default"
  ];
in
{
  imports = [ ./server.nix ];

  config = lib.mkIf config.host.attic.enable {
    systemd.services.attic-watch-store = {
      description = "Watch the Nix store and push new paths to Attic";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        HOME = rootDir;
        XDG_CONFIG_HOME = "/etc";
      };
      serviceConfig = {
        ExecStart = watchStoreCommand;
        Restart = "always";
        RestartSec = "15s";
        WorkingDirectory = rootDir;
      };
    };
  };
}
