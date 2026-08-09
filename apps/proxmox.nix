{
  inputs,
  system,
}:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  facts = import ../facts { lib = pkgs.lib; };
  vmSpecs = builtins.filter (spec: spec.isVM or false) facts.hosts.nixosHostSpecs;
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
    prox-deploy = appSpec proxDeploy "${proxDeploy}/bin/prox-deploy" "Deploy a prox VM via nixmoxer.";
  };
}
