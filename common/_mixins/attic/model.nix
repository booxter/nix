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
    inherit (server) defaultCache endpoint;
    caches = lib.mapAttrs (cacheName: cache: {
      inherit cacheName;
      endpoint = cache.endpoint or server.endpoint;
      public = cache.public or false;
      trustedPublicKey = cache.trustedPublicKey or null;
    }) server.caches;
  }) realmCandidates;
in
{
  inherit realmServers;
}
