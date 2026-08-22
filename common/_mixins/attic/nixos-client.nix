{
  config,
  lib,
  ...
}:
let
  servers = config.host.attic.realmServers;
in
{
  config = lib.mkIf (servers != { }) {
    host.autoUpgrade.claims.attic-client.exclusions = map (server: {
      hosts = [ server.hostName ];
      minimumGapMinutes = 5;
    }) (builtins.attrValues servers);
  };
}
