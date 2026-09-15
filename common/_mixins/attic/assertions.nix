{ config, ... }:
let
  localServer = config.host.attic.realmServers.${config.networking.hostName} or null;
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
        builtins.attrValues config.host.attic.realmServers
      );
      message = "Each Attic server default cache must exist in its cache set";
    }
  ];
}
