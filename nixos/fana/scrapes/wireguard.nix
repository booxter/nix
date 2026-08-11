{
  config,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  wgHome = config.host.wireguard.networks.home;
  gatewayHostConfig = outputs.nixosConfigurations.${wgHome.server.host}.config;
  wgHomeEndpoint = gatewayHostConfig.host.observability.prometheusEndpoints."wg-home";
  gatewayTargetHost = wgHome.server.host;
  peers = lib.mapAttrsToList (name: peer: {
    inherit name;
    inherit (peer) address publicKey;
  }) wgHome.peers;
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
  scrapeConfigs = [
    {
      job_name = "wireguard";
      metrics_path = wgHomeEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${gatewayTargetHost}:${toString wgHomeEndpoint.port}" ];
          labels = {
            component = "wireguard";
            instance = wgHome.server.host;
            scrape_profile = "network";
          };
        }
      ];
      metric_relabel_configs = builtins.concatMap mkPeerMetricRelabels peers;
    }
  ];
}
