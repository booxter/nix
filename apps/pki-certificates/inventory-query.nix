{ repo }:
let
  flake = builtins.getFlake "path:${repo}";
  configurations =
    builtins.mapAttrs (_: value: {
      configuration = "nixosConfigurations";
      inherit value;
    }) flake.nixosConfigurations
    // builtins.mapAttrs (_: value: {
      configuration = "darwinConfigurations";
      inherit value;
    }) flake.darwinConfigurations;
in
import ../../common/_mixins/internal-pki/inventory.nix {
  inherit configurations;
  inherit (flake.inputs.nixpkgs) lib;
  repoRoot = repo;
}
