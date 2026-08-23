{
  fleetInventory,
  inputs,
  outputs,
  system,
}:
let
  nixpkgsInput = if system == "aarch64-darwin" then inputs.nixpkgs-darwin else inputs.nixpkgs;
  lib = nixpkgsInput.lib;
  plainPkgs = nixpkgsInput.legacyPackages.${system};
  pkgs = import nixpkgsInput {
    inherit system;
    config.allowUnfree = true;
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
  };
  autoUpgradeEvaluation = import ./lib/auto-upgrade/evaluate.nix {
    inherit
      fleetInventory
      lib
      outputs
      ;
  };
  appSet = import ./apps {
    inherit
      autoUpgradeEvaluation
      fleetInventory
      inputs
      outputs
      pkgs
      system
      ;
  };
  commonArgs = {
    inherit
      appSet
      autoUpgradeEvaluation
      fleetInventory
      inputs
      lib
      outputs
      pkgs
      plainPkgs
      system
      ;
  };
  modulePaths =
    lib.mapAttrs'
      (fileName: _: lib.nameValuePair (lib.removeSuffix ".nix" fileName) (./per-system + "/${fileName}"))
      (
        lib.filterAttrs (fileName: type: type == "regular" && lib.hasSuffix ".nix" fileName) (
          builtins.readDir ./per-system
        )
      );
in
lib.mapAttrs (_: path: import path commonArgs) modulePaths
