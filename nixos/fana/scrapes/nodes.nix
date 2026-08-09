{
  config,
  facts,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  hostname = config.networking.hostName;
  nixosConfigNames = map (spec: spec.name) facts.hosts.nixosHostSpecs;
  mkNodeLabels = name: hostConfig: isProxmox: {
    availability = hostConfig.host.availability;
    capacity_profile = hostConfig.host.observability.capacityProfile;
    component = "node";
    host_network_charts = lib.boolToString (!isProxmox);
    host_network_source = if isProxmox then "classified" else "node";
    host_class = if hostConfig.host.isVM then "virtual" else "hardware";
    host_virtual = lib.boolToString hostConfig.host.isVM;
    instance = name;
    realm = hostConfig.host.realm;
    scrape_profile = "node";
    thermal_profile = hostConfig.host.observability.thermalProfile;
  };
  mkRemoteNixosNodeTargetConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
    in
    {
      labels = mkNodeLabels name hostConfig hostConfig.host.isProxmox;
      targets = [ "${name}:9100" ];
    };
  nixosNodeExporterTargetNames = builtins.filter (
    name:
    name != "fana" && (outputs.nixosConfigurations.${name}.config.host.observability.enable or false)
  ) nixosConfigNames;
  remoteNixosNonMtlsNodeTargetNames = builtins.filter (
    name:
    !(outputs.nixosConfigurations.${name}.config.host.observability.nodeExporter.mtls.enable or false)
  ) nixosNodeExporterTargetNames;
  remoteNixosNodeTargetConfigs = map mkRemoteNixosNodeTargetConfig nixosNodeExporterTargetNames;
  mkRemoteDarwinNodeTargetConfig =
    name:
    let
      hostConfig = outputs.darwinConfigurations.${name}.config;
    in
    {
      labels = mkNodeLabels name hostConfig false;
      targets = [ "${hostConfig.networking.hostName}:9100" ];
    };
  darwinNodeExporterTargetNames = builtins.filter (
    name: (outputs.darwinConfigurations.${name}.config.host.observability.enable or false)
  ) (builtins.attrNames outputs.darwinConfigurations);
  remoteDarwinNonMtlsNodeTargetNames = builtins.filter (
    name:
    !(outputs.darwinConfigurations.${name}.config.host.observability.nodeExporter.mtls.enable or false)
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
          labels = mkNodeLabels hostname config config.host.isProxmox;
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
