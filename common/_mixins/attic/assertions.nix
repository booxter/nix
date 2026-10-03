{ config, lib, ... }:
let
  localServer = config.host.attic.realmServers.${config.networking.hostName} or null;
  servers = config.host.attic.realmServers;
  publishCaches = config.host.attic.publishCaches;
  publishServerNames = builtins.attrNames publishCaches;
  knownPublishServerNames = builtins.filter (name: builtins.hasAttr name servers) publishServerNames;
in
{
  assertions = [
    {
      assertion =
        localServer == null || localServer.endpoint == config.host.web.services.atticd.internal.url;
      message = "Attic server '${config.networking.hostName}' inventory endpoint must match its internal web URL";
    }
    {
      assertion =
        builtins.all (cacheName: builtins.match "^[A-Za-z0-9][A-Za-z0-9_+-]{0,49}$" cacheName != null)
          (
            builtins.concatLists (
              map (server: builtins.attrNames server.caches) (builtins.attrValues config.host.attic.realmServers)
            )
          );
      message = "Attic cache names must follow Attic's cache naming rules";
    }
    {
      assertion = builtins.all (server: builtins.hasAttr server.defaultCache server.caches) (
        builtins.attrValues servers
      );
      message = "Each Attic server default cache must exist in its cache set";
    }
    {
      assertion = builtins.all (name: builtins.hasAttr name servers) publishServerNames;
      message = "Attic publish targets must reference a realm server";
    }
    {
      assertion = builtins.all (
        serverName:
        builtins.all (cacheName: builtins.hasAttr cacheName servers.${serverName}.caches) (
          publishCaches.${serverName}
        )
      ) knownPublishServerNames;
      message = "Attic publish targets must reference caches on their selected server";
    }
    {
      assertion = builtins.all (
        cacheNames: builtins.length cacheNames == builtins.length (lib.unique cacheNames)
      ) (builtins.attrValues publishCaches);
      message = "Attic publish targets must not contain duplicate cache names";
    }
  ];
}
