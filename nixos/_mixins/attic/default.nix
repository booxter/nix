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
  watchStoreCommand = utils.escapeSystemdExecArgs [
    (lib.getExe pkgs.attic-client)
    "watch-store"
    "default"
  ];
in
lib.mkMerge [
  {
    systemd.services.attic-watch-store = {
      description = "Watch the Nix store and push new paths to Attic";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.HOME = rootDir;
      serviceConfig = {
        ExecStart = watchStoreCommand;
        Restart = "always";
        RestartSec = "15s";
        WorkingDirectory = rootDir;
      };
    };

    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${atticConfigPath}")"
      ${pkgs.coreutils}/bin/ln -sf ${
        config.sops.templates."attic-client-config.toml".path
      } "${atticConfigPath}"
    '';
  }
]
