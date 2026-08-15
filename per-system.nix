{
  inputs,
  outputs,
  system,
}:
let
  lib = inputs.nixpkgs.lib;
  plainPkgs = inputs.nixpkgs.legacyPackages.${system};
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
  };
  appSet = import ./apps {
    inherit
      inputs
      outputs
      pkgs
      system
      ;
  };
  commonArgs = {
    inherit
      appSet
      inputs
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
