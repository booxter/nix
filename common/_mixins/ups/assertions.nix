{
  config,
  fleetInventory,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.ups;
  model = import ./model.nix {
    inherit
      fleetInventory
      lib
      outputs
      ;
  };
  invalidInventoryServers = builtins.filter (
    name: !(builtins.hasAttr name outputs.nixosConfigurations)
  ) (builtins.attrNames model.servers);
  localServer = model.servers.${config.networking.hostName} or null;
  serverName = cfg.client.server;
  server = if serverName == null then null else model.servers.${serverName} or null;
in
{
  config.assertions = [
    {
      assertion = cfg.server == null || config.nixpkgs.hostPlatform.isLinux;
      message = "only a NixOS host may provide a UPS server";
    }
    {
      assertion = cfg.server == null || serverName == null;
      message = "a host cannot be both a UPS server and a UPS client";
    }
    {
      assertion = (cfg.server != null) == (localServer != null);
      message = "local UPS server configuration and fleet inventory must agree";
    }
    {
      assertion = invalidInventoryServers == [ ];
      message = "UPS server inventory entries must name managed NixOS hosts";
    }
  ]
  ++ lib.optionals (cfg.server != null && localServer != null) [
    {
      assertion = localServer.realm == config.host.realm;
      message = "local UPS server inventory realm must match host.realm";
    }
    {
      assertion = localServer.deviceName == cfg.server.name;
      message = "local UPS server inventory device name must match host.ups.server.name";
    }
  ]
  ++ lib.optionals (serverName != null) [
    {
      assertion = builtins.hasAttr serverName model.managedHosts;
      message = "host.ups.client.server must name a managed host";
    }
    {
      assertion = server != null;
      message = "host.ups.client.server must reference an enabled UPS server";
    }
  ];
}
