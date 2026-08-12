{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = hostConfig: {
    cluster = hostConfig.host.proxmox.cluster;
    controller = hostConfig.host.proxmox.controller.enable;
    isGuest = hostConfig.host.isVM;
    isNode = hostConfig.host.isProxmox;
    realm = hostConfig.host.realm;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${hostName} = hostView config;
  };
in
(import ./lib.nix { inherit lib; }).build hosts
