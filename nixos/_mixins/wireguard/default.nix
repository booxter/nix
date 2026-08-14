{ config, ... }:
let
  cfg = config.host.wireguard.server;
in
{
  imports = [
    ./network.nix
    ./observability.nix
    ./qos.nix
  ];

  assertions = [
    {
      assertion = cfg == null || config.host.network.primaryInterface != null;
      message = "WireGuard server requires a primary network interface.";
    }
  ];
}
