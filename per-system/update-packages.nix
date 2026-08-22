{
  lib,
  plainPkgs,
  system,
  ...
}:
let
  pkgs = plainPkgs;
  sharedPackages = import ../pkgs pkgs;
  degoogPackages = import ../nixos/_mixins/degoog/packages.nix { inherit pkgs; };
in
lib.optionalAttrs (lib.hasSuffix "-darwin" system) {
  ismc = pkgs.callPackage ../darwin/_mixins/thermal-accounting/pkgs/ismc { };
}
// lib.optionalAttrs (lib.hasSuffix "-linux" system) {
  inherit (sharedPackages) aiosqlitepool firefox-devtools-mcp;
  aurral = pkgs.callPackage ../nixos/_mixins/aurral/package { };
  inherit (degoogPackages) degoog;
  degoog-devinside-extensions = degoogPackages.devinsideExtensions;
  degoog-georgvwt-extensions = degoogPackages.georgvwtExtensions;
  degoog-official-extensions = degoogPackages.officialExtensions;
  degoog-stackexchange-engine = degoogPackages.stackexchangeEngine;
  degoog-toolkit-extensions = degoogPackages.toolkitExtensions;
  ebook-converter-cli = pkgs.callPackage ../nixos/_mixins/shelfmark/ebook-converter/cli { };
  houndarr = pkgs.callPackage ../nixos/_mixins/houndarr/package {
    inherit (sharedPackages) aiosqlitepool;
  };
  nico-cli = (import ../hm/_mixins/dev/nvidia/pkgs { inherit pkgs; }).nico-cli;
}
