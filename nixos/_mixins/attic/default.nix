{
  config,
  lib,
  hostname,
  pkgs,
  ...
}:
let
  hostSecretFile = ../../../secrets/${hostname}.yaml;
  hasHostSecretFile = builtins.pathExists hostSecretFile;
  rootDir = "/root";
  atticConfigPath = "${rootDir}/.config/attic/config.toml";
  watchStore = pkgs.writeShellApplication {
    name = "attic-watch-store";
    runtimeInputs = [
      pkgs.attic-client
    ];
    text = ''
      set -euo pipefail
      export HOME=${lib.escapeShellArg rootDir}
      exec attic watch-store default
    '';
  };
in
lib.mkMerge [
  # Keep work outputs out of the personal cache to preserve corporate isolation boundaries.
  (lib.optionalAttrs hasHostSecretFile {
    systemd.services.attic-watch-store = {
      description = "Watch the Nix store and push new paths to Attic";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = lib.getExe watchStore;
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
  })
]
