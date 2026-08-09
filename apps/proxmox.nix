{
  facts,
  inputs,
  pkgs,
  system,
}:
let
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  vmSpecs = builtins.filter (spec: spec.isVM or false) facts.hosts.nixosHostSpecs;
  vmTypes = map (spec: spec.name) vmSpecs;
  proxDeploy = pkgs.callPackage ./prox-deploy {
    nixmoxer = proxmoxPkgs.nixmoxer;
    inherit vmTypes;
  };
in
{
  packages = {
    prox-deploy = proxDeploy;
  };
}
