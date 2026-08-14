{
  config,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
  network = config.host.wireguard.networks.${cfg.network};
  internalAddress = "127.0.0.1";
  internalPort = 9587;
  publicPort = 9586;
  metricsName = "wg-${cfg.network}";
  peers = lib.mapAttrsToList (name: peer: {
    inherit name;
    inherit (peer) address publicKey;
  }) network.peers;
  mkPeerMetricRelabels = peer: [
    {
      source_labels = [ "public_key" ];
      target_label = "peer";
      regex = lib.escapeRegex peer.publicKey;
      replacement = peer.name;
    }
    {
      source_labels = [ "public_key" ];
      target_label = "peer_address";
      regex = lib.escapeRegex peer.publicKey;
      replacement = peer.address;
    }
  ];
in
{
  config = lib.mkIf cfg.enable {
    host.observability.prometheusEndpoints.${metricsName} = {
      port = publicPort;
      path = "/metrics";
      upstream = "http://${internalAddress}:${toString internalPort}/metrics";
      serverName = "${config.networking.hostName}.${config.host.network.lanDomain}";
      secretPrefix = "prometheus/${metricsName}";
      scrape = {
        jobName = "wireguard";
        profile = "network";
        component = "wireguard";
        metricRelabelConfigs = lib.concatMap mkPeerMetricRelabels peers;
      };
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
