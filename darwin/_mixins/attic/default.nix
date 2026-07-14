{
  config,
  lib,
  hostname,
  secretDomain,
  pkgs,
  ...
}:
let
  hostSecretFile = ../../../secrets/${secretDomain}/${hostname}.yaml;
  rootDir = "/private/var/root";
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
  {
    launchd.daemons.attic-watch-store = {
      command = lib.escapeShellArg (lib.getExe watchStore);
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        WorkingDirectory = rootDir;
        EnvironmentVariables = {
          HOME = rootDir;
          NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        };
        ProcessType = "Background";
        StandardOutPath = "/var/log/attic-watch-store.log";
        StandardErrorPath = "/var/log/attic-watch-store.log";
      };
    };

    sops.templates."attic-client-config.toml".group = lib.mkForce "wheel";

    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${atticConfigPath}")"
      ${pkgs.coreutils}/bin/ln -sf ${
        config.sops.templates."attic-client-config.toml".path
      } "${atticConfigPath}"
    '';
  }
]
