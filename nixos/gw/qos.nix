{ hostInventory, ... }:
let
  wgHome = hostInventory.site.wireguard.home;
in
{
  # Keep WireGuard peer downloads from filling the constrained home uplink.
  host.qos.interfaces.wan = {
    device = "ens18";
    limits.wireguard-upload = {
      rateMbit = 10;
      queue = "cake";
      match = {
        protocol = "udp";
        sourcePort = wgHome.gateway.listenPort;
      };
    };
  };
}
