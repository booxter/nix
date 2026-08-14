{ config, ... }:
let
  cfg = config.host.wireguard.server;
in
{
  assertions = [
    {
      assertion = cfg == null || config.host.network.primaryInterface != null;
      message = "WireGuard server requires a primary network interface.";
    }
  ];
}
