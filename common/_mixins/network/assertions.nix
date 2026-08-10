{ config, lib, ... }:
let
  cfg = config.host.network;
  wireguardClients = builtins.attrValues cfg.wireguardClients;
in
{
  assertions = [
    {
      assertion = cfg.primaryInterface == null || builtins.hasAttr cfg.primaryInterface cfg.interfaces;
      message = "host.network.primaryInterface must reference a declared host.network.interfaces entry";
    }
    {
      assertion = lib.all (client: client.providesAccessTo != [ ]) wireguardClients;
      message = "host.network.wireguardClients entries must provide access to at least one network";
    }
    {
      assertion =
        let
          interfaces = map (client: client.interface) wireguardClients;
        in
        builtins.length interfaces == builtins.length (lib.unique interfaces);
      message = "host.network.wireguardClients must not declare the same interface more than once";
    }
  ];
}
