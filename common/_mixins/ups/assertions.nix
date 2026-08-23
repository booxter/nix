{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  cfg = config.host.ups;
  hostName = config.networking.hostName;
  localServer = fleetInventory.ups.servers.${hostName} or null;
  clientServerName = fleetInventory.ups.clients.${hostName} or null;
  clientServer =
    if clientServerName == null then null else fleetInventory.ups.servers.${clientServerName} or null;
in
{
  config.assertions = [
    {
      assertion = cfg.server == null || config.nixpkgs.hostPlatform.isLinux;
      message = "only a NixOS host may provide a UPS server";
    }
    {
      assertion = cfg.server == null || clientServerName == null;
      message = "a host cannot be both a UPS server and a UPS client";
    }
    {
      assertion = (cfg.server != null) == (localServer != null);
      message = "local UPS server configuration and fleet inventory must agree";
    }
  ]
  ++ lib.optionals (cfg.server != null && localServer != null) [
    {
      assertion = fleetInventory.hosts.${hostName}.realm == config.host.realm;
      message = "local UPS server inventory realm must match host.realm";
    }
    {
      assertion = localServer.deviceName == cfg.server.name;
      message = "local UPS server inventory device name must match host.ups.server.name";
    }
  ]
  ++ lib.optionals (clientServerName != null) [
    {
      assertion = clientServer != null;
      message = "UPS client inventory must reference an enabled UPS server";
    }
    {
      assertion =
        clientServer == null || fleetInventory.hosts.${clientServerName}.realm == config.host.realm;
      message = "UPS clients and servers must share a realm";
    }
  ];
}
