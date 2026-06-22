{
  hostInventory,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  wgHome = hostInventory.site.wireguard.home;
  gatewayHostConfig = outputs.nixosConfigurations.${wgHome.gateway.host}.config;
  wgHomeEndpoint = gatewayHostConfig.host.observability.client.prometheusMtlsEndpoints."wg-home";
  gatewayTargetHost =
    hostInventory.toNixosShortDnsName
      hostInventory.nixosHostSpecsByName.${wgHome.gateway.host};
  peers = lib.mapAttrsToList (name: peer: {
    inherit name;
    address = builtins.head (lib.splitString "/" peer.address);
    inherit (peer) publicKey;
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
          labels.instance = wgHome.gateway.host;
        }
      ];
      metric_relabel_configs = builtins.concatMap mkPeerMetricRelabels peers;
    }
  ];
}
