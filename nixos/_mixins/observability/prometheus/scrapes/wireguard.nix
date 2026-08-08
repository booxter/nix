{
  hostInventory,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  endpoints = hostInventory.site.wireguard;
  endpointData = lib.mapAttrs (
    name: endpoint:
    let
      gatewayHostConfig = outputs.nixosConfigurations.${endpoint.gateway.host}.config;
    in
    {
      inherit name endpoint;
      metrics = gatewayHostConfig.host.observability.metricsEndpoints."wg-${name}";
      peers = lib.mapAttrsToList (peerName: peer: {
        name = peerName;
        address = builtins.head (lib.splitString "/" peer.address);
        inherit (peer) publicKey;
      }) endpoint.peers;
    }
  ) endpoints;
  metricsPaths = lib.unique (map (data: data.metrics.path) (builtins.attrValues endpointData));
  metricsPath =
    if builtins.length metricsPaths == 1 then
      builtins.head metricsPaths
    else
      throw "WireGuard Prometheus endpoints must expose a common metrics path";
  peers = builtins.concatMap (data: data.peers) (builtins.attrValues endpointData);
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
      metrics_path = metricsPath;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = lib.mapAttrsToList (_: data: {
        targets = [ "${data.endpoint.gateway.host}:${toString data.metrics.port}" ];
        labels = {
          availability = "always";
          component = "wireguard";
          instance = data.endpoint.gateway.host;
          realm = hostInventory.nixosHosts.${data.endpoint.gateway.host}.realm;
          scrape_profile = "network";
        };
      }) endpointData;
      metric_relabel_configs = builtins.concatMap mkPeerMetricRelabels peers;
    }
  ];
}
