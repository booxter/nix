{
  config,
  hostInventory,
  hostSpecName,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  nixosConfigNames = map hostInventory.toNixosConfigName hostInventory.nixosHostSpecs;
  isVirtualNodeName =
    name:
    builtins.hasAttr name hostInventory.nixosHostSpecsByName
    && hostInventory.isNixosVM hostInventory.nixosHostSpecsByName.${name};
  hostClassForName = name: if isVirtualNodeName name then "virtual" else "hardware";
  scrapeExpectationForHostConfig =
    hostConfig: if hostConfig.host.isLaptop then "intermittent" else "always";
  mkRemoteNixosNodeTargetConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
    in
    {
      labels = {
        host_network_charts = lib.boolToString (!hostConfig.host.isProxmox);
        host_network_source = if hostConfig.host.isProxmox then "classified" else "node";
        host_class = hostClassForName name;
        host_virtual = lib.boolToString (isVirtualNodeName name);
        instance = name;
        scrape_expectation = scrapeExpectationForHostConfig hostConfig;
      };
      targets = [ "${hostConfig.host.dnsName}:9100" ];
    };
  nixosNodeExporterTargetNames = builtins.filter (
    name:
    name != "fana"
    && (outputs.nixosConfigurations.${name}.config.host.observability.client.enable or false)
    && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
  ) nixosConfigNames;
  remoteNixosNonMtlsNodeTargetNames = builtins.filter (
    name:
    !(outputs.nixosConfigurations.${name}.config.host.observability.client.nodeExporter.mtls.enable
      or false
    )
  ) nixosNodeExporterTargetNames;
  remoteNixosNodeTargetConfigs = map mkRemoteNixosNodeTargetConfig nixosNodeExporterTargetNames;
  mkRemoteDarwinNodeTargetConfig =
    name:
    let
      hostConfig = outputs.darwinConfigurations.${name}.config;
    in
    {
      labels = {
        host_network_charts = "true";
        host_network_source = "node";
        host_class = "hardware";
        host_virtual = "false";
        instance = name;
        scrape_expectation = scrapeExpectationForHostConfig hostConfig;
      };
      targets = [ "${hostConfig.host.dnsName}:9100" ];
    };
  darwinNodeExporterTargetNames = builtins.filter (
    name:
    (outputs.darwinConfigurations.${name}.config.host.observability.client.enable or false)
    && !(outputs.darwinConfigurations.${name}.config.host.isWork or false)
  ) (builtins.attrNames outputs.darwinConfigurations);
  remoteDarwinNonMtlsNodeTargetNames = builtins.filter (
    name:
    !(outputs.darwinConfigurations.${name}.config.host.observability.client.nodeExporter.mtls.enable
      or false
    )
  ) darwinNodeExporterTargetNames;
  remoteDarwinNodeTargetConfigs = map mkRemoteDarwinNodeTargetConfig darwinNodeExporterTargetNames;
  remoteNodeTargetConfigs = remoteNixosNodeTargetConfigs ++ remoteDarwinNodeTargetConfigs;
in
{
  assertions = [
    {
      assertion = remoteNixosNonMtlsNodeTargetNames == [ ];
      message = "All non-local NixOS Prometheus node scrape targets must use mTLS. Offenders: ${lib.concatStringsSep ", " remoteNixosNonMtlsNodeTargetNames}";
    }
    {
      assertion = remoteDarwinNonMtlsNodeTargetNames == [ ];
      message = "All Darwin Prometheus node scrape targets must use mTLS. Offenders: ${lib.concatStringsSep ", " remoteDarwinNonMtlsNodeTargetNames}";
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
          labels = {
            host_network_charts = "true";
            host_network_source = "node";
            host_class = hostClassForName hostSpecName;
            host_virtual = lib.boolToString (isVirtualNodeName hostSpecName);
            instance = hostSpecName;
            scrape_expectation = scrapeExpectationForHostConfig config;
          };
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
