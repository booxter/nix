{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = hostConfig: {
    guestCluster = hostConfig.host.proxmox.guest.cluster;
    nodeCluster = hostConfig.host.proxmox.node.cluster;
    realm = hostConfig.host.realm;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${hostName} = hostView config;
  };
in
(import ./lib.nix { inherit lib; }).build hosts
