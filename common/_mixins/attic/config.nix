{
  config,
  lib,
  pkgs,
  ...
}:
let
  servers = config.host.attic.realmServers;
  serverNames = builtins.attrNames servers;
  clientConfig = (pkgs.formats.toml { }).generate "attic-client-config.toml" {
    default-server = builtins.head serverNames;
    servers = lib.mapAttrs (_: server: {
      inherit (server) endpoint;
      token = config.sops.placeholder."attic/token";
    }) servers;
  };
in
{
  config = lib.mkIf (servers != { }) {
    sops = {
      secrets."attic/token" = { };
      templates."attic-client-config.toml" = {
        owner = "root";
        group = "root";
        mode = "0400";
        file = clientConfig;
      };
    };
  };
}
