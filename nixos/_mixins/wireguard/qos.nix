{
  config,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
in
{
  config = lib.mkIf (cfg.enable && cfg.qos.uploadLimitMbit != null) {
    host.qos.interfaces.wan = {
      device = config.host.network.primaryInterface;
      limits.wireguard-upload = {
        rateMbit = cfg.qos.uploadLimitMbit;
        queue = "cake";
        match = {
          protocol = "udp";
          sourcePort = cfg.listenPort;
        };
      };
    };
  };
}
