{
  config,
  lib,
  outputs,
  ...
}:
let
  hostName = config.networking.hostName;
  apiCertificateCfg = config.host.proxmox.apiCertificate;
  exporterCfg = config.host.proxmox.prometheusExporter;
  oidcCfg = config.host.proxmox.oidc;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  clusterControllers =
    model.controllersByRealmCluster.${config.host.realm}.${config.host.proxmox.cluster} or [ ];
  participates = config.host.isProxmox || config.host.isVM;
in
{
  config.assertions = [
    {
      assertion = participates == (config.host.proxmox.cluster != null);
      message = "Proxmox nodes and guests must claim a cluster, and other hosts must not claim one";
    }
    {
      assertion = !config.host.isProxmox || config.host.network.primaryInterface != null;
      message = "host.isProxmox requires host.network.primaryInterface";
    }
    {
      assertion = !config.host.proxmox.controller.enable || config.host.isProxmox;
      message = "host.proxmox.controller requires host.isProxmox";
    }
    {
      assertion = !config.host.isProxmox || builtins.length clusterControllers == 1;
      message = "Proxmox cluster '${config.host.proxmox.cluster}' in realm '${config.host.realm}' requires exactly one controller";
    }
    {
      assertion = !apiCertificateCfg.enable || config.services.proxmox-ve.enable;
      message = "host.proxmox.apiCertificate requires services.proxmox-ve.enable.";
    }
    {
      assertion = !oidcCfg.enable || config.services.proxmox-ve.enable;
      message = "host.proxmox.oidc requires services.proxmox-ve.enable.";
    }
    {
      assertion = !oidcCfg.enable || oidcCfg.scopes != [ ];
      message = "host.proxmox.oidc.scopes must not be empty.";
    }
    {
      assertion = !exporterCfg.enable || config.services.proxmox-ve.enable;
      message = "host.proxmox.prometheusExporter requires services.proxmox-ve.enable.";
    }
  ]
  ++ lib.optionals config.host.isVM [
    {
      assertion = model.guestNodes.${hostName} != [ ];
      message = "${hostName} references Proxmox cluster '${config.host.proxmox.cluster}' without any nodes in realm '${config.host.realm}'";
    }
  ];
}
