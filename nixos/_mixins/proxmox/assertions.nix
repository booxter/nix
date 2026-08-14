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
    model.controllersByRealmCluster.${config.host.realm}.${config.host.proxmox.node.cluster} or [ ];
  node = config.host.proxmox.node;
  guest = config.host.proxmox.guest;
  guestUpsServer = model.hosts.${hostName}.upsServer;
  mismatchedUpsNodes = builtins.filter (name: model.hosts.${name}.upsServer != guestUpsServer) (
    model.guestNodes.${hostName} or [ ]
  );
in
{
  config.assertions = [
    {
      assertion = node == null || guest == null;
      message = "a host cannot be both a Proxmox node and guest";
    }
    {
      assertion = node == null || config.host.network.primaryInterface != null;
      message = "host.proxmox.node requires host.network.primaryInterface";
    }
    {
      assertion = node == null || builtins.length clusterControllers == 1;
      message = "Proxmox cluster '${
        if node == null then "" else node.cluster
      }' in realm '${config.host.realm}' requires exactly one controller";
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
  ++ lib.optionals (guest != null) [
    {
      assertion = model.guestNodes.${hostName} != [ ];
      message = "${hostName} references Proxmox cluster '${guest.cluster}' without any nodes in realm '${config.host.realm}'";
    }
    {
      assertion = guestUpsServer == null || mismatchedUpsNodes == [ ];
      message = "${hostName} and its Proxmox nodes must use the same UPS server; mismatched nodes: ${lib.concatStringsSep ", " mismatchedUpsNodes}";
    }
  ];
}
