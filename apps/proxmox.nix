{
  fleetInventory,
  inputs,
  pkgs,
}:
let
  vmSpecs = pkgs.lib.mapAttrs (hostName: clusterName: {
    nodes = fleetInventory.proxmox.clusters.${clusterName}.nodes;
    public_key = fleetInventory.hosts.${hostName}.ssh.publicHostKey;
  }) fleetInventory.proxmox.guests;
  proxDeploy = pkgs.callPackage ./prox-deploy {
    nixmoxer = (pkgs.callPackage (inputs.proxmox-nixos + "/pkgs/nixmoxer") { }).overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./prox-deploy/nixmoxer-return-vmid.patch ];
    });
    inherit vmSpecs;
  };
in
{
  packages = {
    prox-deploy = proxDeploy;
  };
}
