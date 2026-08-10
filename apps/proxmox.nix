{
  inputs,
  outputs,
  pkgs,
  system,
}:
let
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  hostViews = pkgs.lib.mapAttrs (_: configuration: {
    guestCluster = configuration.config.host.proxmox.guest.cluster;
    nodeCluster = configuration.config.host.proxmox.node.cluster;
    realm = configuration.config.host.realm;
  }) outputs.nixosConfigurations;
  proxmoxModel = (import ../nixos/_mixins/proxmox/lib.nix { lib = pkgs.lib; }).build hostViews;
  vmNodes = proxmoxModel.guestNodes;
  proxDeploy = pkgs.callPackage ./prox-deploy {
    nixmoxer = proxmoxPkgs.nixmoxer;
    inherit vmNodes;
  };
in
{
  packages = {
    prox-deploy = proxDeploy;
  };
}
