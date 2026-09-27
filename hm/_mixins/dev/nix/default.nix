{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  nixPkgs = import ./pkgs { inherit pkgs; };
  nixpkgsBuilders = osConfig.host.nix.nixpkgs.builders;
  nixpkgsLocalBuilders = osConfig.host.nix.nixpkgs.local-builders;
  nb = nixPkgs.nb.override {
    builders = nixpkgsBuilders;
    localBuilders = nixpkgsLocalBuilders;
  };
  nr = nixPkgs.nr.override {
    builders = nixpkgsBuilders;
    localBuilders = nixpkgsLocalBuilders;
  };
in
lib.mkIf config.host.hm.env.roles.developer {
  home.packages = with pkgs; [
    hydra-check
    nb
    nh
    nix-init
    nix-output-monitor
    nix-search-cli
    nix-tree
    nixpkgs-reviewFull
    nr
    nurl
  ];
}
