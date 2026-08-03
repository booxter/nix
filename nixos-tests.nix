{ inputs, helpers }:
helpers.forAllSystems (
  system:
  let
    pkgs = import inputs.nixpkgs { inherit system; };
  in
  pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    cache = import ./tests/nixos/cache.nix { inherit pkgs; };
    oauth2-proxy-gate = import ./tests/nixos/oauth2-proxy-gate.nix { inherit pkgs; };
  }
)
