{
  config,
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
in
{
  scrapeConfigs = [
    {
      job_name = "node-local";
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
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = remoteNodeTargetConfigs;
    }
  ];
}
