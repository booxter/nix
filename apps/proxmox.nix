{
  inputs,
  system,
}:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  hostInventory = import ../lib/inventory { lib = pkgs.lib; };
  vmSpecs = builtins.filter (spec: spec.isVM or false) hostInventory.nixosHostSpecs;
  vmTypes = map (spec: spec.name) vmSpecs;
  appSpec = import ./app-spec.nix;
  proxDeploy = pkgs.callPackage ./prox-deploy {
    nixmoxer = proxmoxPkgs.nixmoxer;
    inherit vmTypes;
  };
in
{
  packages = {
    prox-deploy = proxDeploy;
  };
  appSpecs = {
    prox-deploy = appSpec "${proxDeploy}/bin/prox-deploy" "Deploy a prox VM via nixmoxer.";
  };
}
