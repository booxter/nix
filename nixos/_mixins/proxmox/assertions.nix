{
  config,
  facts,
  lib,
  outputs,
  ...
}:
let
  hostName = config.networking.hostName;
  apiCertificateCfg = config.host.proxmox.apiCertificate;
  exporterCfg = config.host.proxmox.prometheusExporter;
  oidcCfg = config.host.proxmox.oidc;
  realmProxmox = facts.realms.${config.host.realm}.services.proxmox or null;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  config.assertions = [
    {
      assertion = !config.host.isProxmox || config.host.network.primaryInterface != null;
      message = "host.isProxmox requires host.network.primaryInterface";
    }
    {
      assertion = (!apiCertificateCfg.enable && !oidcCfg.enable) || realmProxmox != null;
      message = "realm '${config.host.realm}' does not define managed Proxmox services";
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
