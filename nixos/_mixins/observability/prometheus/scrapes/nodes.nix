{
  config,
  lib,
  observabilityInventory,
  prometheusMtlsTlsConfig,
}:
let
  hostName = config.networking.hostName;
  remoteNodes = lib.filter (node: node != null) (
    map (inventory: inventory.node) (
      builtins.attrValues (removeAttrs observabilityInventory.all [ hostName ])
    )
  );
  nonMtlsNodes = map (node: node.labels.instance) (builtins.filter (node: !node.mtls) remoteNodes);
  remoteNodeTargetConfigs = map (node: {
    targets = [ node.target ];
    inherit (node) labels;
  }) remoteNodes;
  localNode = config.host.observability.inventory.node;
in
{
  assertions = [
    {
      assertion = nonMtlsNodes == [ ];
      message = "All remote Prometheus node scrape targets must use mTLS. Offenders: ${lib.concatStringsSep ", " nonMtlsNodes}";
    }
  ];

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
