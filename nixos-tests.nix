{ inputs, helpers }:
helpers.forAllSystems (
  system:
  let
    pkgs = import inputs.nixpkgs { inherit system; };
  in
  pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    cache = import ./tests/nixos/cache.nix { inherit pkgs; };
  }
)
