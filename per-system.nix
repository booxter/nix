{
  facts,
  inputs,
  outputs,
  system,
}:
let
  plainPkgs = inputs.nixpkgs.legacyPackages.${system};
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
  };
  plainFleet = import ./apps/fleet.nix {
    pkgs = plainPkgs;
  };
  fleet = import ./apps/fleet.nix {
    inherit pkgs;
  };
  packageUpdates = import ./apps/package-updates { inherit pkgs; };
  proxmox = import ./apps/proxmox.nix { inherit inputs system; };
  sops = import ./apps/sops {
    sopsTools = pkgs.sops-tools;
  };
  fact = import ./apps/fact.nix { inherit facts pkgs; };
  appSet = import ./apps {
    inherit
      fact
      fleet
      packageUpdates
      pkgs
      proxmox
      sops
      ;
  };
in
{
  inherit (appSet) apps;
  checks = appSet.packages // import ./checks.nix { inherit pkgs; };
  packages = import ./packages.nix {
    inherit
      inputs
      system
      ;
    fleet = plainFleet;
    pkgs = plainPkgs;
  };
  formatter = import ./fmt plainPkgs;
}
