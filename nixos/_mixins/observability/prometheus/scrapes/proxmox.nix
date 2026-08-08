{
  config,
  hostInventory,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  realmProxmox = hostInventory.realms.${config.host.realm}.services.proxmox;
  clusters = builtins.attrValues realmProxmox.clusters;
  proxmoxNodeNames = lib.unique (lib.concatMap (cluster: cluster.nodes) clusters);
  exporterNodeNames = builtins.filter (
    name: outputs.nixosConfigurations.${name}.config.host.proxmox.prometheusExporter.enable
  ) proxmoxNodeNames;
  monitoringNodeNames = map (cluster: cluster.monitoringNode) (
    builtins.filter (cluster: cluster ? monitoringNode) clusters
  );
  mkProxmoxPveTargetConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      endpoint = hostConfig.host.observability.metricsEndpoints.pve;
    in
    {
      labels = {
        availability = hostConfig.host.availability;
        component = "proxmox";
        instance = name;
        proxmox_node = hostConfig.networking.hostName;
        pve_target = hostConfig.host.proxmox.apiCertificate.serverName;
        realm = hostConfig.host.realm;
        scrape_profile = "hypervisor";
      };
      targets = [ "${name}:${toString endpoint.port}" ];
    };
  proxmoxPveTargetConfigs = map mkProxmoxPveTargetConfig exporterNodeNames;
  proxmoxClusterTargetConfigs = map mkProxmoxPveTargetConfig monitoringNodeNames;
  proxmoxPveRelabelConfigs = [
    {
      source_labels = [ "pve_target" ];
      target_label = "__param_target";
    }
  ];
in
{
  assertions = [
    {
      assertion = lib.all (name: builtins.elem name exporterNodeNames) monitoringNodeNames;
      message = "Each Proxmox monitoring node must enable the Prometheus exporter";
    }
  ];

  scrapeConfigs = [
    {
      job_name = "proxmox-pve-cluster";
      metrics_path = "/pve";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      params = {
        module = [ "default" ];
        cluster = [ "1" ];
        node = [ "0" ];
      };
      static_configs = proxmoxClusterTargetConfigs;
      relabel_configs = proxmoxPveRelabelConfigs;
    }
    {
      job_name = "proxmox-pve-node";
      metrics_path = "/pve";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      params = {
        module = [ "default" ];
        cluster = [ "0" ];
        node = [ "1" ];
      };
      static_configs = proxmoxPveTargetConfigs;
      relabel_configs = proxmoxPveRelabelConfigs;
    }
    {
      job_name = "proxmox-pve-exporter";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = proxmoxPveTargetConfigs;
    }
  ];
}
