{ config, ... }:
let
  cfg = config.host.wireguard.server;
in
{
  assertions = [
    {
      assertion = !cfg.enable || config.host.network.primaryInterface != null;
      message = "WireGuard server ${cfg.network} requires a primary network interface.";
    }
  ];
}
