{
  config,
  fleetInventory,
  lib,
}:
let
  realmCandidates = lib.filterAttrs (
    _: server: server.realm == config.host.realm
  ) fleetInventory.atticServers;
  realmServers = lib.mapAttrs (hostName: server: {
    inherit hostName;
    inherit (server)
      cacheName
      endpoint
      trustedPublicKey
      ;
  }) realmCandidates;
in
{
  inherit realmServers;
}
