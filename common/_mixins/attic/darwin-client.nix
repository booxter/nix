{
  config,
  lib,
  pkgs,
  ...
}:
let
  rootDir = "/private/var/root";
  atticConfigPath = "${rootDir}/.config/attic/config.toml";
  servers = config.host.attic.realmServers;
in
{
  config = lib.mkIf config.host.attic.client.enable {
    launchd.daemons = lib.mapAttrs' (
      name: server:
      lib.nameValuePair "attic-watch-store-${name}" {
        command = lib.escapeShellArgs [
          (lib.getExe pkgs.attic-client)
          "watch-store"
          "${name}:${server.cacheName}"
        ];
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
      }
    ) servers;

    sops.templates."attic-client-config.toml".group = lib.mkForce "wheel";

    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${atticConfigPath}")"
      ${pkgs.coreutils}/bin/ln -sf ${
        config.sops.templates."attic-client-config.toml".path
      } "${atticConfigPath}"
    '';
  };
}
