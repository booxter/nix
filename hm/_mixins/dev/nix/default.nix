{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  nixPkgs = import ./pkgs { inherit pkgs; };
  nr = nixPkgs.nr.override {
    builders = osConfig.host.nix.nixpkgs-review.builders;
  };
in
lib.mkIf config.host.hm.env.roles.developer {
  home.packages = with pkgs; [
    hydra-check
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
