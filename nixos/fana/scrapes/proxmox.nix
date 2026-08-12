{
  config,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  localHost = config.networking.hostName;
  model = import ../../_mixins/proxmox/model.nix {
    inherit config lib outputs;
  };
  hostConfigFor =
    name: if name == localHost then config else outputs.nixosConfigurations.${name}.config;
  exporterEnabled = name: (hostConfigFor name).host.proxmox.prometheusExporter.enable;
  proxmoxNodeNames = builtins.filter (name: exporterEnabled name) (builtins.attrNames model.nodes);
  clusterRepresentativeNames = builtins.concatLists (
    lib.mapAttrsToList (
      _: clusters:
      lib.concatMap (
        nodeNames:
        let
          exporterNodeNames = builtins.filter exporterEnabled nodeNames;
        in
        lib.optional (exporterNodeNames != [ ]) (builtins.head exporterNodeNames)
      ) (builtins.attrValues clusters)
    ) model.nodesByRealmCluster
  );
  mkProxmoxPveTargetConfig =
    name:
    let
      hostConfig = hostConfigFor name;
      endpoint = hostConfig.host.observability.prometheusEndpoints.pve;
    in
    {
      labels = {
        component = "proxmox";
        instance = name;
        proxmox_node = hostConfig.networking.hostName;
        pve_target = hostConfig.host.proxmox.apiCertificate.serverName;
        scrape_profile = "hypervisor";
      };
      targets = [ "${name}:${toString endpoint.port}" ];
    };
  proxmoxPveTargetConfigs = map mkProxmoxPveTargetConfig proxmoxNodeNames;
  proxmoxClusterTargetConfigs = map mkProxmoxPveTargetConfig clusterRepresentativeNames;
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
