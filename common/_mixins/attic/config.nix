{
  config,
  lib,
  pkgs,
  ...
}:
let
  servers = config.host.attic.realmServers;
  serverNames = builtins.attrNames servers;
  rootDir = if pkgs.stdenv.isDarwin then "/private/var/root" else "/root";
  atticConfigPath = "${rootDir}/.config/attic/config.toml";
  endpointHost =
    endpoint:
    let
      match = builtins.match "https://([^/:]+)(:[0-9]+)?(/.*)?" endpoint;
    in
    if match == null then
      throw "Attic endpoint must be an HTTPS URL: ${endpoint}"
    else
      builtins.elemAt match 0;
  clientConfig = (pkgs.formats.toml { }).generate "attic-client-config.toml" {
    default-server = builtins.head serverNames;
    servers = lib.mapAttrs (_: server: {
      inherit (server) endpoint;
      token = config.sops.placeholder."attic/token";
    }) servers;
  };
  pushCommands = lib.mapAttrsToList (name: server: ''
    ${lib.getExe pkgs.attic-client} push --jobs 1 ${lib.escapeShellArg "${name}:${server.defaultCache}"} $OUT_PATHS || true
  '') servers;
  postBuildHook = pkgs.writeShellScript "attic-push-hook" ''
    set -eu
    set -f
    export HOME=${lib.escapeShellArg rootDir}
    export NIX_REMOTE=daemon
    ${lib.optionalString pkgs.stdenv.isDarwin ''
      export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    ''}
    ${lib.concatStrings pushCommands}
  '';
in
{
  config = lib.mkIf (servers != { }) {
    host.nix.netrcMachines = lib.mapAttrs' (
      _: server:
      lib.nameValuePair (endpointHost server.endpoint) {
        password = config.sops.placeholder."attic/token";
      }
    ) servers;

    nix.settings.post-build-hook = postBuildHook;

    sops = {
      secrets."attic/token" = { };
      templates."attic-client-config.toml" = {
        owner = "root";
        group = if pkgs.stdenv.isDarwin then "wheel" else "root";
        mode = "0400";
        file = clientConfig;
      };
    };

    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${atticConfigPath}")"
      ${pkgs.coreutils}/bin/ln -sf ${
        config.sops.templates."attic-client-config.toml".path
      } "${atticConfigPath}"
    '';
  };
}
