{
  config,
  hostInventory,
  ...
}:
let
  wgHome = hostInventory.site.wireguard.home;
in
{
  # Keep WireGuard peer downloads from filling the constrained home uplink.
  host.qos.interfaces.wan = {
    device = config.host.network.primaryInterface;
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
