{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
  internalAddress = "127.0.0.1";
  internalPort = 9587;
  publicPort = 9586;
  metricsName = "wg-${cfg.network}";
in
{
  config = lib.mkIf cfg.enable {
    host.observability.prometheusEndpoints.${metricsName} = {
      enable = true;
      port = publicPort;
      path = "/metrics";
      upstream = "http://${internalAddress}:${toString internalPort}/metrics";
      serverName = "${config.networking.hostName}.${facts.site.lan.domain}";
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
