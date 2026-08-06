{
  config,
  lib,
  pkgs,
  ...
}:
let
  rootDir = "/private/var/root";
  atticConfigPath = "${rootDir}/.config/attic/config.toml";
in
{
  config = lib.mkIf (!config.host.isWork) {
    launchd.daemons.attic-watch-store = {
      serviceConfig = {
        ProgramArguments = [
          (lib.getExe pkgs.attic-client)
          "watch-store"
          "default"
        ];
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
  };
}
