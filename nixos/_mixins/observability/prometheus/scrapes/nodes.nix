{
  config,
  fleetInventory,
  observabilityCatalog,
  prometheusMtlsTlsConfig,
}:
let
  hostName = config.networking.hostName;
  remoteNodes = builtins.attrValues (removeAttrs observabilityCatalog.nodes [ hostName ]);
  remoteNodeTargetConfigs = map (node: {
    targets = [ node.target ];
    inherit (node) labels;
  }) remoteNodes;
  localNode = observabilityCatalog.nodes.${hostName};
  cakeNodes = map (name: observabilityCatalog.nodes.${name}) fleetInventory.observability.cakeSources;
  omitCake = [
    {
      source_labels = [ "__name__" ];
      regex = "host_observability_cake_.*";
      action = "drop";
    }
  ];
in
{
  scrapeConfigs = [
    {
      job_name = "node-local";
      metric_relabel_configs = omitCake;
      static_configs = [
        {
          targets = [
            "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
          ];
          inherit (localNode) labels;
        }
      ];
    }
    {
      job_name = "node-mtls";
      metric_relabel_configs = omitCake;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = remoteNodeTargetConfigs;
    }
    {
      job_name = "cake";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      scrape_interval = "5s";
      scrape_timeout = "4s";
      params."collect[]" = [ "textfile" ];
      static_configs = map (node: {
        targets = [ node.target ];
        labels = node.labels // {
          component = "cake";
          scrape_profile = "network";
        };
      }) cakeNodes;
      metric_relabel_configs = [
        {
          source_labels = [ "__name__" ];
          regex = "host_observability_cake_.*";
          action = "keep";
        }
      ];
    }
  ];
}
