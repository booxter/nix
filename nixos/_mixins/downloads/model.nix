{ config, lib }:
{
  routes = lib.mapAttrs (
    name: route:
    let
      claim = config.host.storage.claims.${route.storage.claim} or null;
    in
    route
    // {
      inherit claim name;
      clientName = route.client;
      client = config.host.downloads.clients.${route.client} or null;
      path = if claim == null then null else "${claim.mountPoint}/${route.storage.relativePath}";
    }
  ) config.host.downloads.routes;
}
