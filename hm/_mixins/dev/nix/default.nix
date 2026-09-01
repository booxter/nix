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
  nb = nixPkgs.nb.override {
    builders = nixpkgsBuilders;
  };
  nr = nixPkgs.nr.override {
    builders = nixpkgsBuilders;
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
