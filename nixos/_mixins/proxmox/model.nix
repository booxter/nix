{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = name: hostConfig: {
    cluster =
      if hostConfig.host.proxmox.node != null then
        hostConfig.host.proxmox.node.cluster
      else if hostConfig.host.proxmox.guest != null then
        hostConfig.host.proxmox.guest.cluster
      else
        null;
    controller = hostConfig.host.proxmox.node != null && hostConfig.host.proxmox.node.controller;
    isNode = hostConfig.host.proxmox.node != null;
    realm = hostConfig.host.realm;
    upsServer = if hostConfig.host.ups.server != null then name else hostConfig.host.ups.client.server;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  hosts =
    lib.mapAttrs (name: configuration: hostView name configuration.config) otherConfigurations
    // {
      ${hostName} = hostView hostName config;
    };
  local = hosts.${hostName};
  nodes = lib.filterAttrs (
    _: host: host.isNode && host.realm == local.realm && host.cluster == local.cluster
  ) hosts;
in
{
  inherit hosts;
  nodeNames = builtins.attrNames nodes;
  controllerNames = builtins.attrNames (lib.filterAttrs (_: host: host.controller) nodes);
}
