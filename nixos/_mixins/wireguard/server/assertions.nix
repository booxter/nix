{ config, ... }:
let
  cfg = config.host.wireguard.server;
in
{
  assertions = [
    {
      assertion = cfg.network == null || config.host.network.primaryInterface != null;
      message = "WireGuard server ${toString cfg.network} requires a primary network interface.";
    }
  ];
}
