{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
  network = facts.site.wireguard.${cfg.network};
in
{
  config = lib.mkIf (cfg.network != null) {
    host.qos.interfaces.wan = {
      device = config.host.network.primaryInterface;
      limits.wireguard-upload = {
        rateMbit = network.gateway.qos.uploadLimitMbit;
        queue = "cake";
        match = {
          protocol = "udp";
          sourcePort = network.gateway.listenPort;
        };
      };
    };
  };
}
