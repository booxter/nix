{
  fleetInventory,
  inputs,
  pkgs,
  system,
}:
let
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  vmNodes = pkgs.lib.mapAttrs (
    _: clusterName: fleetInventory.proxmox.clusters.${clusterName}.nodes
  ) fleetInventory.proxmox.guests;
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
