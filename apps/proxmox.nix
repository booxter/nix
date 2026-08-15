{
  inputs,
  outputs,
  pkgs,
  system,
}:
let
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  hostViews = pkgs.lib.mapAttrs (_: configuration: {
    cluster =
      if configuration.config.host.proxmox.node != null then
        configuration.config.host.proxmox.node.cluster
      else if configuration.config.host.proxmox.guest != null then
        configuration.config.host.proxmox.guest.cluster
      else
        null;
    isGuest = configuration.config.host.proxmox.guest != null;
    isNode = configuration.config.host.proxmox.node != null;
    realm = configuration.config.host.realm;
  }) outputs.nixosConfigurations;
  vmNodes = import ../nixos/_mixins/proxmox/lib.nix { lib = pkgs.lib; } hostViews;
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
