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
    isGuest = hostConfig.host.proxmox.guest != null;
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
in
(import ./lib.nix { inherit lib; }).build hosts
