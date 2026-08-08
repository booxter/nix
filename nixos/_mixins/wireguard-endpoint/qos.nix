{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.wireguardEndpoint;
  endpoint = hostInventory.site.wireguard.${cfg.name};
in
{
  config = lib.mkIf (cfg.name != null) {
    # Keep WireGuard peer downloads from filling the constrained home uplink.
    host.qos.interfaces.wan = {
      device = config.host.network.primaryInterface;
      limits.wireguard-upload = {
        rateMbit = endpoint.gateway.qos.uploadLimitMbit;
        queue = "cake";
        match = {
          protocol = "udp";
          sourcePort = endpoint.gateway.listenPort;
        };
      };
    };
  };
}
