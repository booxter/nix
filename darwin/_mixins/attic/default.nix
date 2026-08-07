{
  config,
  lib,
  pkgs,
  ...
}:
let
  rootDir = "/private/var/root";
in
{
  config = lib.mkIf config.host.attic.enable {
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
          XDG_CONFIG_HOME = "/etc";
          NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        };
        ProcessType = "Background";
        StandardOutPath = "/var/log/attic-watch-store.log";
        StandardErrorPath = "/var/log/attic-watch-store.log";
      };
    };
  };
}
