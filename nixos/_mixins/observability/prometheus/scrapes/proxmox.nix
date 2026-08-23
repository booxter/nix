{
  lib,
  observabilityCatalog,
  prometheusMtlsTlsConfig,
}:
let
  exporters = observabilityCatalog.proxmoxExporters;
  exportersByRealm = lib.groupBy (exporter: exporter.realm) exporters;
  clusterRepresentatives = builtins.concatLists (
    map (
      realmExporters:
      map lib.head (builtins.attrValues (lib.groupBy (exporter: exporter.cluster) realmExporters))
    ) (builtins.attrValues exportersByRealm)
  );
  mkTarget = exporter: {
    labels = {
      component = "proxmox";
      instance = exporter.node;
      proxmox_node = exporter.node;
      pve_target = exporter.pveTarget;
      scrape_profile = "hypervisor";
    };
    targets = [ exporter.target ];
  };
  relabelConfigs = [
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
      static_configs = map mkTarget clusterRepresentatives;
      relabel_configs = relabelConfigs;
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
      static_configs = map mkTarget exporters;
      relabel_configs = relabelConfigs;
    }
    {
      job_name = "proxmox-pve-exporter";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = map mkTarget exporters;
    }
  ];
}
