{
  config,
  lib,
  pkgs,
  ...
}:
let
  servers = config.host.attic.realmServers;
  publishCaches = config.host.attic.publishCaches;
  publishingServers = lib.filterAttrs (name: _: builtins.hasAttr name publishCaches) servers;
  publishingServerNames = builtins.attrNames publishingServers;
  authenticatedHosts = lib.unique (
    builtins.concatMap (
      server:
      map (cache: endpointHost cache.endpoint) (
        builtins.attrValues (lib.filterAttrs (_: cache: cache.authenticated) server.caches)
      )
    ) (builtins.attrValues publishingServers)
  );
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
    default-server = builtins.head publishingServerNames;
    servers = lib.mapAttrs (_: server: {
      inherit (server) endpoint;
      token = config.sops.placeholder."attic/token";
    }) publishingServers;
  };
  pushCommands = lib.concatLists (
    lib.mapAttrsToList (
      serverName: cacheNames:
      map (cacheName: ''
        ${lib.getExe pkgs.attic-client} push --jobs 1 ${lib.escapeShellArg "${serverName}:${cacheName}"} $OUT_PATHS || true
      '') cacheNames
    ) publishCaches
  );
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
  config = lib.mkIf (publishCaches != { }) {
    host.nix.netrcMachines = lib.listToAttrs (
      map (hostName: {
        name = hostName;
        value = {
          password = config.sops.placeholder."attic/token";
        };
      }) authenticatedHosts
    );

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
