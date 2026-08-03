{
  inputs,
  system,
}:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  hostInventory = import ../lib/inventory.nix { lib = pkgs.lib; };
  vmSpecs = builtins.filter hostInventory.isNixosVM hostInventory.nixosHostSpecs;
  vmTypes = map (spec: spec.name) vmSpecs;
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
  proxDeploy = pkgs.callPackage ./prox-deploy {
    nixmoxer = proxmoxPkgs.nixmoxer;
    inherit vmTypes;
  };
in
{
  packages = {
    prox-deploy = proxDeploy;
  };
  apps = {
    prox-deploy = mkApp "${proxDeploy}/bin/prox-deploy" "Deploy a prox VM via nixmoxer.";
  };
}
