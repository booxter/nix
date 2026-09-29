{
  config,
  fleetInventory,
  lib,
}:
let
  serverFor = hostName: server: {
    inherit hostName;
    inherit (server) defaultCache endpoint;
    caches = lib.mapAttrs (cacheName: cache: {
      inherit cacheName;
      endpoint = cache.endpoint or server.endpoint;
      public = cache.public or false;
      trustedPublicKey = cache.trustedPublicKey or null;
    }) server.caches;
  };
  realmCandidates = lib.filterAttrs (
    _: server: server.realm == config.host.realm
  ) fleetInventory.atticServers;
  publicCandidates = lib.filterAttrs (
    _: server: server.realm != config.host.realm
  ) fleetInventory.atticServers;
  realmServers = lib.mapAttrs serverFor realmCandidates;
  publicServers = lib.mapAttrs (
    hostName: server:
    let
      normalized = serverFor hostName server;
    in
    normalized // { caches = lib.filterAttrs (_: cache: cache.public) normalized.caches; }
  ) publicCandidates;
in
{
  inherit publicServers realmServers;
}
