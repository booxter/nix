{
  inputs,
  outputs,
  system,
  username,
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
    inherit username;
    pkgs = plainPkgs;
  };
  fleet = import ./apps/fleet.nix {
    inherit pkgs username;
  };
  packageUpdates = import ./apps/package-updates { inherit pkgs; };
  proxmox = import ./apps/proxmox.nix { inherit inputs system; };
  sops = import ./apps/sops {
    sopsTools = pkgs.sops-tools;
  };
in
{
  apps = import ./apps {
    inherit
      fleet
      packageUpdates
      pkgs
      proxmox
      sops
      ;
  };
  checks = import ./checks.nix {
    inherit
      fleet
      packageUpdates
      pkgs
      proxmox
      ;
  };
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
