{
  hostInventory,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  nixosConfigNames = map hostInventory.toNixosConfigName hostInventory.nixosHostSpecs;
  proxmoxLabNodeNames = builtins.filter (
    name:
    (outputs.nixosConfigurations.${name}.config.host.isProxmox or false)
    && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
    && (outputs.nixosConfigurations.${name}.config.host.proxmox.prometheusExporter.enable or false)
  ) nixosConfigNames;
  proxmoxClusterScrapeNodeName = "prx1-lab";
  mkProxmoxPveTargetConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      endpoint = hostConfig.host.observability.client.prometheusMtlsEndpoints.pve;
    in
    {
      labels = {
        instance = hostConfig.host.dnsName;
        proxmox_node = hostConfig.networking.hostName;
        pve_target = hostConfig.host.proxmox.apiCertificate.serverName;
      };
      targets = [ "${hostConfig.host.dnsName}:${toString endpoint.port}" ];
    };
  proxmoxPveTargetConfigs = map mkProxmoxPveTargetConfig proxmoxLabNodeNames;
  proxmoxClusterTargetConfigs = [ (mkProxmoxPveTargetConfig proxmoxClusterScrapeNodeName) ];
  proxmoxPveRelabelConfigs = [
    {
      source_labels = [ "pve_target" ];
      target_label = "__param_target";
    }
  ];
in
{
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
