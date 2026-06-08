{
  config,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  proxmoxLabNodeNames = builtins.filter (
    name:
    !(lib.hasPrefix "local-" name)
    && (outputs.nixosConfigurations.${name}.config.host.isProxmox or false)
    && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
    && (outputs.nixosConfigurations.${name}.config.host.proxmox.prometheusExporter.enable or false)
  ) (builtins.attrNames outputs.nixosConfigurations);
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
  mkProxmoxApiTargetConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      apiCertificate = hostConfig.host.proxmox.apiCertificate;
    in
    {
      labels = {
        instance = hostConfig.host.dnsName;
        proxmox_node = hostConfig.networking.hostName;
      };
      targets = [
        "https://${apiCertificate.serverName}:${toString apiCertificate.port}/"
      ];
    };
  proxmoxApiTargetConfigs = map mkProxmoxApiTargetConfig proxmoxLabNodeNames;
  proxmoxPveRelabelConfigs = [
    {
      source_labels = [ "pve_target" ];
      target_label = "__param_target";
    }
  ];
  proxmoxApiRelabelConfigs = [
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target" ];
      target_label = "target";
    }
    {
      replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
      target_label = "__address__";
    }
  ];
in
{
  scrapeConfigs = [
    {
      job_name = "blackbox-proxmox-api";
      metrics_path = "/probe";
      params.module = [ "http_service" ];
      static_configs = proxmoxApiTargetConfigs;
      relabel_configs = proxmoxApiRelabelConfigs;
    }
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
