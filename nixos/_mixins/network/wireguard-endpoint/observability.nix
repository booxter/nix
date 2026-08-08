{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.wireguardEndpoint;
  endpoint = hostInventory.site.wireguard.${cfg.name};
  internalAddress = "127.0.0.1";
  internalPort = 9587;
  publicPort = 9586;
  metricsName = "wg-${cfg.name}";
in
{
  config = lib.mkIf (cfg.name != null) {
    host.observability.metricsEndpoints.${metricsName} = {
      enable = true;
      port = publicPort;
      path = "/metrics";
      upstream = "http://${internalAddress}:${toString internalPort}/metrics";
      serverName = "${endpoint.gateway.host}.${hostInventory.site.lan.domain}";
      secretPrefix = "prometheus/${metricsName}";
    };

    services.prometheus.exporters.wireguard = {
      enable = true;
      listenAddress = internalAddress;
      port = internalPort;
      interfaces = [ cfg.interface ];
      withRemoteIp = true;
      latestHandshakeDelay = true;
      openFirewall = false;
    };

    systemd.services.prometheus-wireguard-exporter = {
      wants = [
        "network-online.target"
        "wireguard-${cfg.interface}.service"
      ];
      after = [
        "network-online.target"
        "wireguard-${cfg.interface}.service"
      ];
    };
  };
}
