{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = name: hostConfig: {
    cluster = hostConfig.host.proxmox.cluster;
    controller = hostConfig.host.proxmox.controller.enable;
    isGuest = hostConfig.host.proxmox.guest.enable;
    isNode = hostConfig.host.proxmox.node.enable;
    realm = hostConfig.host.realm;
    upsServer = if hostConfig.host.ups.server.enable then name else hostConfig.host.ups.client.server;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  hosts =
    lib.mapAttrs (name: configuration: hostView name configuration.config) otherConfigurations
    // {
      ${hostName} = hostView hostName config;
    };
in
(import ./lib.nix { inherit lib; }).build hosts
